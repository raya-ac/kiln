import SwiftUI

// MARK: - Color Palette

extension Color {
    // Backgrounds
    static let kilnBg = Color(hex: 0x0A0A0B)
    static let kilnSurface = Color(hex: 0x141415)
    static let kilnSurfaceElevated = Color(hex: 0x1C1C1E)
    static let kilnSurfaceHover = Color(hex: 0x242426)

    // Borders
    static let kilnBorder = Color(hex: 0x2A2A2C)
    static let kilnBorderSubtle = Color(hex: 0x1E1E20)

    // Text
    static let kilnText = Color(hex: 0xE4E4E7)
    static let kilnTextSecondary = Color(hex: 0x8B8B8E)
    static let kilnTextTertiary = Color(hex: 0x56565A)

    // Accent
    /// User-configurable accent color. Reads the current setting from
    /// UserDefaults so every `Color.kilnAccent` reference in the app
    /// automatically respects the user's choice. Falls back to orange.
    static var kilnAccent: Color {
        let hex = (UserDefaults.standard.string(forKey: "kiln.accentHex") ?? "").trimmingCharacters(in: .whitespaces)
        if hex.isEmpty { return Color(hex: 0xF59E0B) }
        return Color(hexString: hex)
    }
    static var kilnAccentHover: Color { Color(hex: 0xFBBF24) }
    static var kilnAccentMuted: Color {
        let hex = (UserDefaults.standard.string(forKey: "kiln.accentHex") ?? "").trimmingCharacters(in: .whitespaces)
        if hex.isEmpty { return Color(hex: 0xF59E0B).opacity(0.15) }
        return Color(hexString: hex).opacity(0.15)
    }

    // Semantic
    static let kilnError = Color(hex: 0xEF4444)
    static let kilnSuccess = Color(hex: 0x22C55E)

    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    /// Accent color environment key — views that want the user-chosen accent
    /// read `@Environment(\.kilnAccent)`; views that use `Color.kilnAccent`
    /// directly stay with the default orange.
    static var kilnAccentDefault: Color { Color(hex: 0xF59E0B) }

    /// Accepts "F59E0B", "#F59E0B", or "0xF59E0B". Falls back to kilnAccent.
    init(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s = String(s.dropFirst(2)) }
        if let v = UInt(s, radix: 16) {
            self.init(hex: v)
        } else {
            self.init(hex: 0xF59E0B)
        }
    }
}

// MARK: - Environment Keys (for customizable theme values)

private struct KilnAccentKey: EnvironmentKey {
    static let defaultValue: Color = Color(hex: 0xF59E0B)
}

private struct KilnFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var kilnAccent: Color {
        get { self[KilnAccentKey.self] }
        set { self[KilnAccentKey.self] = newValue }
    }

    var kilnFontScale: CGFloat {
        get { self[KilnFontScaleKey.self] }
        set { self[KilnFontScaleKey.self] = newValue }
    }
}

extension View {
    /// Scale a fixed system font size by the environment's kilnFontScale.
    func kilnScaledFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(KilnScaledFontModifier(size: size, weight: weight, design: design))
    }
}

private struct KilnScaledFontModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    @Environment(\.kilnFontScale) private var scale
    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight, design: design))
    }
}

// MARK: - View Modifiers

struct KilnPanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.kilnBg)
    }
}

extension View {
    func kilnPanel() -> some View {
        modifier(KilnPanelStyle())
    }
}
