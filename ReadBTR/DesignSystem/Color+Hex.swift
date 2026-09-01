import SwiftUI
import UIKit

extension Color {
    /// Parses a `#RRGGBB`/`RRGGBB` or `#RRGGBBAA`/`RRGGBBAA` hex string, as
    /// stored in `ReaderTheme`. Falls back to a mid-gray if malformed —
    /// invalid input shouldn't crash rendering, just look obviously off.
    init(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexString.removeAll { $0 == "#" }

        var value: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&value)

        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        switch hexString.count {
        case 8:
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255
            alpha = Double(value & 0xFF) / 255
        case 6:
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
            alpha = 1
        default:
            red = 0.5
            green = 0.5
            blue = 0.5
            alpha = 1
        }

        self.init(red: red, green: green, blue: blue, opacity: alpha)
    }

    /// Round-trip counterpart to `init(hex:)` — used by `ConfigurationView`'s
    /// `ColorPicker` bindings, since `ReaderTheme` stores colors as hex
    /// strings, not `Color` values. `getRed(_:green:blue:alpha:)` normalizes
    /// through RGB regardless of the underlying color space, unlike reading
    /// `CGColor.components` directly (which can come back as grayscale
    /// white+alpha for some system-picked colors).
    var hexString: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
    }
}
