import Foundation
import ObjectiveC
import Testing
import UIKit
import WebKit

@testable import ReadBTR

/// Regression coverage for a `GuidedReadingHighlighter.js` bug: a `Range`
/// spanning a paragraph with an `<em>`/`<strong>` run in the middle of an
/// otherwise-single visual line gets back *multiple* rects from
/// `Range.getClientRects()` — one per inline-element boundary, not one per
/// actual visual line, since each inline run is its own box in WebKit's
/// render tree even when it shares a line with its neighbors. Left
/// untreated, the highlighter split that one real line into several
/// "lines" right at the italic boundary, so `refreshLines()`/`lineCount()`
/// over-reported and the highlight box visibly split in two around
/// italicized text. `mergeSameLineRects` (`GuidedReadingHighlighter.js`) is
/// the fix.
///
/// These tests exercise the real, shipped JS file directly against a real
/// `WKWebView` with hand-crafted HTML — the same file
/// `GuidedReadingNavigatorController` injects into an actual EPUB resource
/// in production, not a copy — so they'd have caught this bug and will
/// catch any regression of it.
@MainActor
struct GuidedReadingHighlighterJSTests {
    private enum TestError: Error {
        case missingResource
    }

    /// Bridges `WKNavigationDelegate`'s callback-based API to async/await.
    /// Kept as its own object rather than folded into the struct itself,
    /// since `WKWebView.navigationDelegate` holds its delegate *weakly* and
    /// needs something with real identity to retain for the load's
    /// duration — see `makeHighlightedWebView`'s associated-object retain.
    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?

        func wait(for webView: WKWebView, loading html: String) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.continuation = continuation
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    private static var associatedWindowKey: UInt8 = 0
    private static var associatedWaiterKey: UInt8 = 0

    /// Loads `html` into a real, on-screen-sized `WKWebView`, injects the
    /// actual `GuidedReadingHighlighter.js` bundled into the app (via
    /// `Bundle.main`, exactly how `GuidedReadingNavigatorController` loads
    /// it in production — `ReadBTRTests` runs hosted inside the `ReadBTR`
    /// app, per its `TEST_HOST` build setting, so this is the real bundled
    /// resource, not a stand-in), and runs `refreshLines()` so the rest of
    /// `window.__guidedReading` is ready to query.
    ///
    /// A real `UIWindow`/navigation delegate back this webview and need to
    /// outlive the test's remaining calls into it, but threading them
    /// through every call site would clutter each test — associating them
    /// with the webview's own lifetime keeps callers down to one line.
    private static func makeHighlightedWebView(
        html: String, width: CGFloat = 800, height: CGFloat = 600
    ) async throws -> WKWebView {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(webView)
        window.makeKeyAndVisible()

        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        try await waiter.wait(for: webView, loading: html)

        objc_setAssociatedObject(webView, &associatedWindowKey, window, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(webView, &associatedWaiterKey, waiter, .OBJC_ASSOCIATION_RETAIN)

        guard let scriptURL = Bundle.main.url(forResource: "GuidedReadingHighlighter", withExtension: "js") else {
            throw TestError.missingResource
        }
        let source = try String(contentsOf: scriptURL, encoding: .utf8)
        _ = try await webView.evaluateJavaScript(source)

        // `didFinish` navigation fires once the DOM is parsed, but a
        // viewport-meta-driven reflow (narrower/wider than the page's
        // initial guess) can still be pending a frame or two after that —
        // confirmed empirically as a source of flakiness here, the same
        // "no officially exposed layout-ready signal" gap
        // `GuidedReadingViewModel.awaitLinesReady` already works around in
        // production. Polling `refreshLines()` until two consecutive reads
        // agree is the same "trust convergence, not a fixed delay" idea.
        var previousCount = -1
        for _ in 0..<20 {
            _ = try await webView.evaluateJavaScript("window.__guidedReading.refreshLines()")
            let count = try await Self.lineCount(webView)
            if count == previousCount { break }
            previousCount = count
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        return webView
    }

    private static func lineCount(_ webView: WKWebView) async throws -> Int {
        let value = try await webView.evaluateJavaScript("window.__guidedReading.lineCount()")
        return (value as? NSNumber)?.intValue ?? 0
    }

    private static func lineText(_ webView: WKWebView, at index: Int) async throws -> String? {
        try await webView.evaluateJavaScript("window.__guidedReading.lineText(\(index))") as? String
    }

    /// The core regression case: a paragraph with an `<em>` run in the
    /// middle, laid out in a viewport wide enough that the whole sentence
    /// fits on one visual line. Before the fix, the plain-before/italic/
    /// plain-after fragments each produced their own `getClientRects()`
    /// rect, so `refreshLines()` reported 3 "lines" (and split the
    /// highlight into 3 pieces) for what is visually a single line.
    @Test func italicMidLineDoesNotSplitASingleVisualLineInTwo() async throws {
        let html = """
            <html>
            <head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
            <body style="margin:0;font-size:24px;font-family:-apple-system;">
            <p>Plain text before, <em>an italicized phrase</em>, and plain text after.</p>
            </body></html>
            """
        // Wide enough (relative to the short sentence above) that it's
        // unambiguously one visual line, regardless of exact font metrics —
        // the point of this test is the italic boundary mid-line, not
        // wrapping.
        let webView = try await Self.makeHighlightedWebView(html: html, width: 2000, height: 200)

        #expect(try await Self.lineCount(webView) == 1)
        let text = try await Self.lineText(webView, at: 0)
        #expect(text == "Plain text before, an italicized phrase, and plain text after.")
    }

    /// Same shape with a `<strong>` run instead of `<em>` — the fix merges
    /// on rect geometry, not on the italic tag specifically, so any inline
    /// element boundary mid-line should be covered the same way.
    @Test func boldMidLineDoesNotSplitASingleVisualLineInTwo() async throws {
        let html = """
            <html>
            <head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
            <body style="margin:0;font-size:24px;font-family:-apple-system;">
            <p>Plain text before, <strong>a bolded phrase</strong>, and plain text after.</p>
            </body></html>
            """
        let webView = try await Self.makeHighlightedWebView(html: html, width: 2000, height: 200)

        #expect(try await Self.lineCount(webView) == 1)
    }

    /// A paragraph with an italic run comfortably inside its first wrapped
    /// line, followed by enough plain text to force a genuinely separate
    /// second real line — guards against the fix overcorrecting into
    /// merging two *actually different* lines into one just because an
    /// italic run happens to be somewhere in the block. (Deliberately keeps
    /// the italic run away from the exact wrap point itself — a browser
    /// wrapping mid-element is its own separate layout question, not what
    /// this bug was about.)
    @Test func italicOnOneWrappedLineDoesNotMergeIntoTheNextLine() async throws {
        let html = """
            <html>
            <head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
            <body style="margin:0;font-size:24px;font-family:-apple-system;">
            <p style="width:220px;">Some <em>italicized</em> words start this paragraph off, and then \
            enough additional plain text follows to reliably wrap onto a second, wholly separate visual \
            line further down.</p>
            </body></html>
            """
        let webView = try await Self.makeHighlightedWebView(html: html, width: 320, height: 600)

        let count = try await Self.lineCount(webView)
        #expect(count >= 2)

        // Every reported line should have real, non-empty text, and none of
        // the source text should have been silently dropped or duplicated
        // at the italic boundary or at the wrap.
        var combined = ""
        for index in 0..<count {
            let text = try await Self.lineText(webView, at: index)
            #expect(text?.isEmpty == false)
            combined += (combined.isEmpty ? "" : " ") + (text ?? "")
        }
        #expect(combined.contains("italicized"))
        #expect(combined.contains("separate visual"))

        // The italic run's own line shouldn't have absorbed the entire rest
        // of the paragraph — that's exactly the "merged everything" failure
        // mode an over-broad merge tolerance would produce.
        let firstLine = try await Self.lineText(webView, at: 0)
        #expect(firstLine?.contains("separate visual") == false)
    }
}
