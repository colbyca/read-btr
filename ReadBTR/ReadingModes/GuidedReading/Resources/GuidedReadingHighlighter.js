// GuidedReadingHighlighter.js
//
// Injected into each EPUB resource's WebView by
// GuidedReadingNavigatorController (design-roadmap.md §6.4). Computes real
// on-screen line rects directly off the rendered DOM — the same
// `Range.getClientRects()` primitive Readium's own decorator.js uses to
// size its highlight boxes (see swift-toolkit's rect.js,
// `getClientRectsNoOverlap`) — and draws its own highlight overlay / drives
// its own line-to-line scroll. None of this goes through Readium's
// Decoration API or `go(to:)` navigation; those stay reserved for coarse,
// whole-resource jumps (chapter select, crossing into the next resource).
(function () {
    "use strict";

    var lines = null; // [{ text, top, left, width, height }], document-space
    var highlightEl = null;
    var currentIndex = -1;

    // Fraction of the viewport height where an auto-scrolled-to line
    // should land — comfortably above center so a few lines of upcoming
    // context are always visible below it.
    var ANCHOR_FRACTION = 0.35;

    function isVisibleTextNode(node) {
        var text = node.textContent;
        if (!text || !text.trim()) return false;
        var parent = node.parentElement;
        if (!parent) return false;
        var tag = parent.tagName;
        if (tag === "SCRIPT" || tag === "STYLE" || tag === "NOSCRIPT") return false;
        var style = window.getComputedStyle(parent);
        if (style.display === "none" || style.visibility === "hidden") return false;
        return true;
    }

    // Block-level elements likely to hold a run of flowing text. Lines are
    // computed per *block*, not per text node — a paragraph containing
    // `<em>`/`<strong>`/`<a>` spans is still one continuous flow of text
    // that can wrap across the same visual lines as its surrounding plain
    // text, and treating each inline-formatted run as its own separate
    // "line" (the original, simpler implementation) undercounts how many
    // visual lines a paragraph like that actually occupies — confirmed
    // empirically: it made the highlight advance less than one real line
    // per step whenever it crossed italic/bold text.
    var BLOCK_SELECTOR = "p, h1, h2, h3, h4, h5, h6, li, blockquote, dd, dt, td, th, figcaption, div";

    function collectBlockElements() {
        if (!document.body) return [];
        var candidates = Array.prototype.slice.call(document.body.querySelectorAll(BLOCK_SELECTOR));
        return candidates.filter(function (el) {
            if (!el.textContent || !el.textContent.trim()) return false;
            var style = window.getComputedStyle(el);
            if (style.display === "none" || style.visibility === "hidden") return false;
            // Prefer the leaf-level block (e.g. a <p>) over anything that
            // merely *wraps* one (e.g. a <div> containing several <p>s) —
            // otherwise the wrapper's text gets counted a second time,
            // once for itself and once for each child block.
            for (var i = 0; i < candidates.length; i++) {
                if (candidates[i] !== el && el.contains(candidates[i])) return false;
            }
            return true;
        });
    }

    function textNodesIn(el) {
        var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, null);
        var nodes = [];
        var node;
        while ((node = walker.nextNode())) {
            if (isVisibleTextNode(node)) nodes.push(node);
        }
        return nodes;
    }

    // `Range.getClientRects()` gives one rect per *fragment*, not one rect
    // per visual line — when a line is made up of several inline runs (e.g.
    // plain text, then an `<em>` run, then more plain text), each run is a
    // separate box in WebKit's render tree and contributes its own rect
    // even though all three sit on the same line. Left untreated, that
    // fragments a single visual line into several "lines" right at the
    // italic/bold boundary — confirmed empirically as the cause of the
    // highlight visibly splitting in two around italicized text. This
    // merges any consecutive rects whose `top` values are nearly identical
    // (i.e. they're the same line box, just different fragments of it)
    // into one rect spanning their combined bounds, before line boundaries
    // are ever computed from them.
    //
    // Deliberately *not* "do their vertical spans overlap" — line boxes
    // tile a block with no gap between them (line N's `bottom` commonly
    // equals line N+1's `top` exactly), so an overlap test merges every
    // real line in the block into one giant blob. Comparing `top` values
    // with a tolerance well under a line's own height only catches true
    // same-line fragments (whose tops differ by at most a sub-pixel
    // rounding/font-metrics nudge), not adjacent-but-distinct lines (whose
    // tops differ by roughly a full line height).
    function mergeSameLineRects(rects) {
        var merged = [];
        for (var i = 0; i < rects.length; i++) {
            var r = rects[i];
            // Degenerate rects show up at element boundaries (a zero-width
            // caret-position rect between two adjacent inline elements) and
            // contribute nothing worth merging or keeping as their own line.
            if (r.width <= 0 && r.height <= 0) continue;
            var last = merged.length ? merged[merged.length - 1] : null;
            var tolerance = last ? Math.min(r.height, last.bottom - last.top) / 2 : 0;
            var sameLine = last && Math.abs(r.top - last.top) <= tolerance;
            if (sameLine) {
                last.left = Math.min(last.left, r.left);
                last.right = Math.max(last.right, r.left + r.width);
                last.top = Math.min(last.top, r.top);
                last.bottom = Math.max(last.bottom, r.top + r.height);
            } else {
                merged.push({ left: r.left, right: r.left + r.width, top: r.top, bottom: r.top + r.height });
            }
        }
        return merged.map(function (r) {
            return { top: r.top, left: r.left, width: r.right - r.left, height: r.bottom - r.top };
        });
    }

    // Splits one block element into its visual lines. The block's text may
    // be spread across several text nodes (plain text interleaved with
    // `<em>`/`<strong>`/`<a>` runs) — this flattens them into one logical
    // string with a per-character lookup back to (node, offset), so a
    // single `Range` can span across those inline boundaries the same way
    // the rendered text itself does, and `getClientRects()` over that
    // whole range — once fragment rects sharing a line are merged back
    // together by `mergeSameLineRects` — gives one rect per *actual*
    // visual line regardless of how many DOM nodes contributed to it. A
    // binary search per rect then finds where each line begins, the same
    // technique as before, just over the flattened map instead of one
    // node's own text.
    function linesForBlock(el) {
        var nodes = textNodesIn(el);
        if (nodes.length === 0) return [];

        var text = "";
        var map = []; // map[i] = { node, offset } for character i of `text`
        for (var n = 0; n < nodes.length; n++) {
            var nodeText = nodes[n].textContent;
            for (var i = 0; i < nodeText.length; i++) {
                map.push({ node: nodes[n], offset: i });
            }
            text += nodeText;
        }
        var len = text.length;
        if (len === 0) return [];

        var probe = document.createRange();
        function rangeAt(start, end) {
            var startPos = map[start];
            var endPos = map[Math.min(end, len) - 1];
            probe.setStart(startPos.node, startPos.offset);
            probe.setEnd(endPos.node, endPos.offset + 1);
            return probe;
        }
        function topAt(offset) {
            var rects = rangeAt(offset, offset + 1).getClientRects();
            return rects.length ? rects[0].top : null;
        }

        var lineRects = mergeSameLineRects(Array.prototype.slice.call(rangeAt(0, len).getClientRects()));
        if (lineRects.length === 0) return [];

        var results = [];
        var searchFloor = 0;
        for (var li = 0; li < lineRects.length; li++) {
            var targetTop = lineRects[li].top;
            var lo = searchFloor;
            var hi = len;
            while (lo < hi) {
                var mid = (lo + hi) >> 1;
                var top = topAt(mid);
                if (top === null || top >= targetTop - 1) {
                    hi = mid;
                } else {
                    lo = mid + 1;
                }
            }
            results.push({ start: lo, rect: lineRects[li] });
            searchFloor = lo + 1;
        }

        return results
            .map(function (r, index) {
                var end = index + 1 < results.length ? results[index + 1].start : len;
                return {
                    text: text.slice(r.start, end).trim(),
                    top: r.rect.top + window.scrollY,
                    left: r.rect.left + window.scrollX,
                    width: r.rect.width,
                    height: r.rect.height,
                };
            })
            .filter(function (line) {
                return line.text.length > 0;
            });
    }

    function refreshLines() {
        var collected = [];
        collectBlockElements().forEach(function (el) {
            linesForBlock(el).forEach(function (line) {
                collected.push(line);
            });
        });
        // Reading order is top-to-bottom, then left-to-right for anything
        // sharing a line — matches the order `querySelectorAll` already
        // visits elements in, this just cleans up float/inline edge cases
        // without reordering the common case.
        collected.sort(function (a, b) {
            return a.top - b.top || a.left - b.left;
        });
        lines = collected;
        highlightEl = null;
        currentIndex = -1;
        return lines.length;
    }

    // ReadiumCSS applies its own broad, `!important`-flagged reset rules to
    // enforce the reader's chosen theme over whatever the publisher's own
    // stylesheet says (confirmed empirically: an inline `background-color`
    // set the normal way — `el.style.backgroundColor = ...` — was silently
    // discarded, `getComputedStyle` showing `transparent` despite
    // `el.style.backgroundColor` still reporting the color we set). A
    // plain inline declaration loses to that; an `!important` inline
    // declaration — set via `setProperty(..., "important")`, not plain
    // assignment — wins, since inline `!important` outranks stylesheet
    // `!important` of the same (author) origin.
    function setImportant(el, property, value) {
        el.style.setProperty(property, value, "important");
    }

    function ensureHighlightElement() {
        if (highlightEl) return highlightEl;
        var el = document.createElement("div");
        el.id = "__guided-reading-highlight";
        setImportant(el, "position", "absolute");
        setImportant(el, "pointer-events", "none");
        setImportant(el, "border-radius", "3px");
        setImportant(el, "transition", "none");
        setImportant(el, "z-index", "2147483647");
        setImportant(el, "border", "none");
        setImportant(el, "margin", "0");
        setImportant(el, "padding", "0");
        document.body.appendChild(el);
        highlightEl = el;
        return el;
    }

    function highlightLine(index, colorHex, isActive) {
        if (!lines || index < 0 || index >= lines.length) return;
        var line = lines[index];
        var el = ensureHighlightElement();
        var pad = 2;
        setImportant(el, "top", line.top - pad + "px");
        setImportant(el, "left", line.left - pad + "px");
        setImportant(el, "width", line.width + pad * 2 + "px");
        setImportant(el, "height", line.height + pad * 2 + "px");
        setImportant(el, "background-color", colorHex);
        setImportant(el, "opacity", isActive ? "0.55" : "0.35");
        currentIndex = index;
    }

    function clearHighlight() {
        if (highlightEl) setImportant(highlightEl, "width", "0px");
        currentIndex = -1;
    }

    function scrollToLine(index, animated) {
        if (!lines || index < 0 || index >= lines.length) return;
        var line = lines[index];
        var targetTop = Math.max(0, line.top - window.innerHeight * ANCHOR_FRACTION);
        window.scrollTo({ top: targetTop, left: 0, behavior: animated ? "smooth" : "auto" });
    }

    function currentVisibleLineIndex() {
        if (!lines || lines.length === 0) return -1;
        var anchorY = window.scrollY + window.innerHeight * ANCHOR_FRACTION;
        var best = 0;
        var bestDistance = Infinity;
        for (var i = 0; i < lines.length; i++) {
            var distance = Math.abs(lines[i].top - anchorY);
            if (distance < bestDistance) {
                bestDistance = distance;
                best = i;
            }
        }
        return best;
    }

    function lineText(index) {
        if (!lines || index < 0 || index >= lines.length) return null;
        return lines[index].text;
    }

    document.addEventListener(
        "click",
        function (event) {
            var onHighlight = false;
            if (highlightEl && currentIndex >= 0) {
                var rect = highlightEl.getBoundingClientRect();
                onHighlight =
                    event.clientX >= rect.left &&
                    event.clientX <= rect.right &&
                    event.clientY >= rect.top &&
                    event.clientY <= rect.bottom;
            }
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.guidedReading) {
                window.webkit.messageHandlers.guidedReading.postMessage({ type: "tap", onHighlight: onHighlight });
            }
        },
        true
    );

    // Debug-only introspection — reports back exactly what the highlight
    // element (if any) actually rendered as, so a "why isn't the highlight
    // visible" report can be diagnosed from real DOM state instead of
    // guessed at from a screenshot alone.
    function debugSnapshot() {
        var el = document.getElementById("__guided-reading-highlight");
        var elRect = el ? el.getBoundingClientRect() : null;
        var computed = el ? window.getComputedStyle(el) : null;
        return JSON.stringify({
            hasElement: !!el,
            elRect: elRect
                ? { top: elRect.top, left: elRect.left, width: elRect.width, height: elRect.height }
                : null,
            elStyle: el
                ? {
                      top: el.style.top,
                      left: el.style.left,
                      width: el.style.width,
                      height: el.style.height,
                      backgroundColor: el.style.backgroundColor,
                      opacity: el.style.opacity,
                      zIndex: el.style.zIndex,
                      position: el.style.position,
                  }
                : null,
            elComputed: computed
                ? {
                      backgroundColor: computed.backgroundColor,
                      opacity: computed.opacity,
                      display: computed.display,
                      visibility: computed.visibility,
                      position: computed.position,
                      zIndex: computed.zIndex,
                      clipPath: computed.clipPath,
                      filter: computed.filter,
                      mixBlendMode: computed.mixBlendMode,
                  }
                : null,
            elParent: el && el.parentElement ? el.parentElement.tagName : null,
            nextSiblingCount: el ? Array.prototype.filter.call(document.body.children, function (c) {
                return c !== el;
            }).length : -1,
            scrollY: window.scrollY,
            innerHeight: window.innerHeight,
            lineCount: lines ? lines.length : -1,
            currentIndex: currentIndex,
            currentLine: lines && currentIndex >= 0 && currentIndex < lines.length ? lines[currentIndex] : null,
            bodyPosition: document.body ? getComputedStyle(document.body).position : null,
            htmlPosition: getComputedStyle(document.documentElement).position,
        });
    }

    window.__guidedReading = {
        refreshLines: refreshLines,
        highlightLine: highlightLine,
        clearHighlight: clearHighlight,
        scrollToLine: scrollToLine,
        currentVisibleLineIndex: currentVisibleLineIndex,
        lineText: lineText,
        lineCount: function () {
            return lines ? lines.length : 0;
        },
        debugSnapshot: debugSnapshot,
    };
})();
