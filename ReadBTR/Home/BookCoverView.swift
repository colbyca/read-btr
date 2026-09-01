import SwiftUI

/// One library grid cell. Falls back to a plain tile with the title when
/// there's no cover image — cover extraction is explicitly non-fatal at
/// import time (design-roadmap.md §5.4), so this has to look reasonable
/// either way.
struct BookCoverView: View {
    let book: Book

    @State private var coverImage: UIImage?

    var body: some View {
        ZStack {
            if let coverImage {
                Image(uiImage: coverImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)
                Text(book.title)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(8)
                    .lineLimit(4)
            }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: book.relativeCoverImagePath) {
            coverImage = Self.loadCover(for: book)
        }
    }

    private static func loadCover(for book: Book) -> UIImage? {
        guard
            let relativePath = book.relativeCoverImagePath,
            let url = try? BookFileStorage().absoluteURL(forRelativePath: relativePath)
        else {
            return nil
        }
        return UIImage(contentsOfFile: url.path)
    }
}
