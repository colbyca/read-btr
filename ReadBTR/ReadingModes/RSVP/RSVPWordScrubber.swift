import SwiftUI

/// The toolbar's word strip — centered on the current word with neighbors
/// visible on either side; scrolling it moves the reading position, reusing
/// the same `WordStream` data RSVP already has, no separate seek mechanism
/// (design-roadmap.md §6.3).
///
/// Uses `ScrollViewReader.scrollTo` for programmatic centering (the
/// well-established, reliable mechanism) and `.scrollPosition(id:)` purely
/// to read back where the user's own drag left the strip — the newer
/// binding API's own `anchor:`-based centering did not reliably center on
/// first appearance in testing (confirmed via simulator screenshot, not
/// just inferred), so it isn't relied on for the write direction here.
struct RSVPWordScrubber: View {
    let stream: WordStream
    let currentIndex: Int
    let onSelect: (Int) -> Void

    @State private var scrollPosition: Int?

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 20) {
                        ForEach(Array(stream.words.enumerated()), id: \.offset) { index, segment in
                            Text(segment.text)
                                .font(index == currentIndex ? .title3.weight(.semibold) : .body)
                                .foregroundStyle(index == currentIndex ? Color.primary : Color.secondary)
                                .id(index)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, geometry.size.width / 2)
                }
                .scrollPosition(id: $scrollPosition)
            }
            .onAppear {
                scrollPosition = currentIndex
                // Deferred one run-loop turn: calling `scrollTo` in the same
                // pass as the view's insertion, before the GeometryReader
                // has a real size to compute centering padding from, did
                // not reliably center on first appearance (confirmed via
                // simulator screenshot).
                DispatchQueue.main.async {
                    proxy.scrollTo(currentIndex, anchor: .center)
                }
            }
            .onChange(of: currentIndex) { _, newValue in
                guard scrollPosition != newValue else { return }
                withAnimation {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .frame(height: 44)
        .onChange(of: scrollPosition) { _, newValue in
            guard let newValue, newValue != currentIndex else { return }
            onSelect(newValue)
        }
    }
}
