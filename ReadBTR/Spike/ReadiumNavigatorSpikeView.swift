import ReadiumNavigator
// `@preconcurrency`: Readium's core model types (Publication, Asset, ...)
// aren't Sendable-annotated yet, which trips Swift 6 strict concurrency the
// moment they cross back into this file's @MainActor context. Downgrades
// those diagnostics to warnings rather than restructuring a throwaway spike
// around it.
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer
import SwiftUI
import UIKit

/// Throwaway spike, not production code (see dev.md §9, phase 2).
///
/// Phase 1 (`ReadiumSpikeTests`) verified the Content/Locator model in
/// isolation. This phase checks the thing that only shows up on a real
/// screen: does applying a `Decoration` to a sentence-level `Locator`
/// actually render a visible highlight in Readium's EPUB `WKWebView`
/// navigator, decoupled from any TTS/audio playback?
enum ReadiumNavigatorSpike {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static var fixtureURL: URL {
        get throws {
            guard let url = Bundle.main.url(forResource: "alice", withExtension: "epub") else {
                throw Failure(description: "alice.epub not found in app bundle")
            }
            return url
        }
    }

    /// Opens the fixture, locates the opening sentence of Chapter I (skipping
    /// the Project Gutenberg boilerplate that precedes it), and builds an
    /// `EPUBNavigatorViewController` starting right at that sentence so it's
    /// on screen without needing to navigate first.
    @MainActor
    static func makeReader() async throws -> (navigator: EPUBNavigatorViewController, sentenceLocator: Locator) {
        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        let publicationOpener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )

        guard let fileURL = FileURL(url: try fixtureURL) else {
            throw Failure(description: "could not build a FileURL for the fixture")
        }

        let asset = try await assetRetriever.retrieve(url: fileURL).get()
        let publication = try await publicationOpener.open(
            asset: asset,
            allowUserInteraction: false
        ).get()

        guard let content = publication.content() else {
            throw Failure(description: "publication.content() returned nil")
        }

        let textElements = await content.elements().compactMap { $0 as? TextContentElement }
        guard let chapterOpening = textElements.first(where: { ($0.text ?? "").contains("Alice was beginning") }) else {
            throw Failure(description: "could not find the Chapter I opening paragraph")
        }

        let sentenceTokenizer = makeTextContentTokenizer(
            defaultLanguage: publication.metadata.language,
            textTokenizerFactory: { language in
                makeDefaultTextTokenizer(unit: .sentence, language: language)
            }
        )
        let sentenceElements = try sentenceTokenizer(chapterOpening)
        guard
            let firstSentence = sentenceElements.first as? TextContentElement,
            let sentenceLocator = firstSentence.segments.first?.locator
        else {
            throw Failure(description: "sentence tokenizer produced no segments")
        }

        let navigator = try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: sentenceLocator
        )

        return (navigator, sentenceLocator)
    }
}

/// Hosts the Navigator's `UIViewController` per Readium's SwiftUI integration
/// guide — the Navigator is UIKit-only, so it has to be added as a child
/// view controller rather than driven purely from SwiftUI.
final class ReadiumSpikeHostViewController: UIViewController {
    private let navigator: EPUBNavigatorViewController

    init(navigator: EPUBNavigatorViewController) {
        self.navigator = navigator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(navigator)
        navigator.view.frame = view.bounds
        navigator.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(navigator.view)
        navigator.didMove(toParent: self)
    }
}

struct ReadiumSpikeHostViewControllerRepresentable: UIViewControllerRepresentable {
    let viewController: ReadiumSpikeHostViewController

    func makeUIViewController(context: Context) -> ReadiumSpikeHostViewController {
        viewController
    }

    func updateUIViewController(_ uiViewController: ReadiumSpikeHostViewController, context: Context) {}
}

struct ReadiumNavigatorSpikeScreen: View {
    @Environment(\.dismiss) private var dismiss

    @State private var host: ReadiumSpikeHostViewController?
    @State private var statusMessage = "Loading spike…"

    var body: some View {
        NavigationStack {
            Group {
                if let host {
                    ReadiumSpikeHostViewControllerRepresentable(viewController: host)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
            }
            .navigationTitle("Navigator Spike")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            do {
                let (navigator, locator) = try await ReadiumNavigatorSpike.makeReader()
                let host = ReadiumSpikeHostViewController(navigator: navigator)
                self.host = host

                // The WebView needs a beat to finish its initial render
                // before a decoration will actually paint. `apply` is safe
                // to call any time per the Decorations guide, but for a
                // visual spike we want to be sure it's visible by the time
                // a screenshot is taken.
                try await Task.sleep(nanoseconds: 800_000_000)

                navigator.apply(
                    decorations: [
                        Decoration(
                            id: "spike-sentence",
                            locator: locator,
                            style: .highlight(tint: .systemYellow)
                        ),
                    ],
                    in: "spike-highlight"
                )
            } catch {
                statusMessage = "Spike failed: \(error)"
            }
        }
    }
}
