import Foundation
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer

/// Thin wrapper around the Readium `AssetRetriever` + `PublicationOpener`
/// pipeline proven in the phase-1/2 spikes (dev.md §9) — the one place the
/// rest of the app goes to turn a local EPUB file into a `Publication`.
struct PublicationLoader {
    enum LoaderError: Error {
        case invalidFileURL
    }

    private let assetRetriever: AssetRetriever
    private let publicationOpener: PublicationOpener

    init() {
        let httpClient = DefaultHTTPClient()
        assetRetriever = AssetRetriever(httpClient: httpClient)
        publicationOpener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )
    }

    func open(fileURL: URL) async throws -> Publication {
        guard let url = FileURL(url: fileURL) else {
            throw LoaderError.invalidFileURL
        }
        let asset = try await assetRetriever.retrieve(url: url).get()
        return try await publicationOpener.open(asset: asset, allowUserInteraction: false).get()
    }
}
