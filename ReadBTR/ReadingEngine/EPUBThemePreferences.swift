import ReadiumNavigator

/// Maps `ReaderTheme` onto Readium's own `EPUBPreferences` — the reader
/// surface stays themed independently of the app chrome even when rendered
/// through Readium's stock WebView navigator (dev.md §10.2). Shared by
/// every EPUB-navigator-hosting reading mode (Guided Reading, Normal) so
/// this mapping — and its two non-obvious normalizations — lives in one
/// place rather than being copy-pasted per mode.
enum EPUBThemePreferences {
    static func make(for theme: ReaderTheme, scroll: Bool) -> EPUBPreferences {
        var preferences = EPUBPreferences()
        preferences.scroll = scroll
        // Many EPUBPreferences overrides are ignored unless publisher
        // styles are off, per Readium's own preferences documentation.
        preferences.publisherStyles = false
        preferences.backgroundColor = ReadiumNavigator.Color(hex: theme.backgroundColorHex)
        preferences.textColor = ReadiumNavigator.Color(hex: theme.textColorHex)
        preferences.fontFamily = theme.fontName.map { FontFamily(rawValue: $0) }
        // Readium's fontSize/pageMargins preferences are scale factors, not
        // point values — normalized against this app's own ReaderTheme
        // defaults (18pt font / 24pt margin) so a theme left at its defaults
        // renders at Readium's own 100% baseline.
        preferences.fontSize = theme.fontSize / 18.0
        preferences.lineHeight = theme.lineSpacing
        preferences.pageMargins = theme.marginPoints / 24.0
        return preferences
    }
}
