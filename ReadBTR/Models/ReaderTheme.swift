import Foundation

/// Appearance of the reader surface — deliberately independent of the app
/// chrome's Catppuccin palette (dev.md §10.2). `AppSettings.defaultTheme`
/// holds the global default; `Book.themeOverride` overrides it per book.
struct ReaderTheme: Codable, Equatable {
    var backgroundColorHex: String
    var textColorHex: String
    var highlightColorHex: String
    var fontName: String?
    var fontSize: Double
    var lineSpacing: Double
    var marginPoints: Double

    /// Plain, neutral "paper" look — intentionally not Catppuccin-flavored,
    /// since the reader surface is meant to be themeable independently of
    /// the rest of the app (dev.md §10.2).
    static let `default` = ReaderTheme(
        backgroundColorHex: "#FDFDFD",
        textColorHex: "#1A1A1A",
        highlightColorHex: "#FFE699",
        fontName: nil,
        fontSize: 18,
        lineSpacing: 1.4,
        marginPoints: 24
    )
}
