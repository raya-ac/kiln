import AppKit
import SwiftUI

// MARK: - Dynamic color helper

/// Returns a Color that resolves to `light` under Aqua (and its HC variant)
/// and to `dark` under DarkAqua. SwiftUI's `preferredColorScheme(...)` flows
/// through the window's effective appearance, which NSColor dynamic providers
/// evaluate at draw time — so these Colors auto-flip with the theme setting.
private func kilnDyn(_ light: UInt, _ dark: UInt) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(hex: isDark ? dark : light)
    })
}

extension NSColor {
    /// Convenience initializer from a packed RGB int (0xRRGGBB).
    convenience init(hex: UInt, alpha: CGFloat = 1.0) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - Color Palette

extension Color {
    // Backgrounds
    static let kilnBg = kilnDyn(0xFAFAF9, 0x0A0A0B)
    static let kilnSurface = kilnDyn(0xFFFFFF, 0x141415)
    static let kilnSurfaceElevated = kilnDyn(0xF4F4F5, 0x1C1C1E)
    static let kilnSurfaceHover = kilnDyn(0xE4E4E7, 0x242426)

    // Borders
    static let kilnBorder = kilnDyn(0xD4D4D8, 0x2A2A2C)
    static let kilnBorderSubtle = kilnDyn(0xE4E4E7, 0x1E1E20)

    // Text
    static let kilnText = kilnDyn(0x09090B, 0xE4E4E7)
    static let kilnTextSecondary = kilnDyn(0x52525B, 0x8B8B8E)
    static let kilnTextTertiary = kilnDyn(0x71717A, 0x56565A)

    // Accent
    /// User-configurable accent color. Reads the current setting from
    /// UserDefaults so every `Color.kilnAccent` reference in the app
    /// automatically respects the user's choice. Falls back to orange.
    /// Accent is the same hue in both modes — we're not remapping the
    /// user's chosen brand color per appearance.
    static var kilnAccent: Color {
        let hex = (UserDefaults.standard.string(forKey: "kiln.accentHex") ?? "").trimmingCharacters(in: .whitespaces)
        if hex.isEmpty { return Color(hex: 0xF59E0B) }
        return Color(hexString: hex)
    }
    static var kilnAccentHover: Color { Color(hex: 0xFBBF24) }
    static var kilnAccentMuted: Color {
        let hex = (UserDefaults.standard.string(forKey: "kiln.accentHex") ?? "").trimmingCharacters(in: .whitespaces)
        // Slightly stronger tint in light mode — 15% alpha on orange against
        // a near-white background is nearly invisible. Read the stored theme
        // mode rather than NSApp.effectiveAppearance to avoid main-actor
        // isolation requirements at color-lookup time.
        let alpha: Double = (Self.kilnThemeMode == .light) ? 0.22 : 0.15
        if hex.isEmpty { return Color(hex: 0xF59E0B).opacity(alpha) }
        return Color(hexString: hex).opacity(alpha)
    }

    // Semantic — same hues in both modes for recognizability.
    static let kilnError = Color(hex: 0xEF4444)
    static let kilnSuccess = Color(hex: 0x22C55E)

    /// The user's current theme mode, read from UserDefaults. Sheet-backed
    /// views that don't carry `AppStore` in their environment use this to
    /// honor the setting without needing the store injected.
    static var kilnThemeMode: ThemeMode {
        let raw = UserDefaults.standard.string(forKey: "kiln.themeMode") ?? ""
        return ThemeMode(rawValue: raw) ?? .system
    }

    /// SwiftUI color scheme derived from `kilnThemeMode`. `nil` = follow
    /// system. Pass directly to `.preferredColorScheme(...)`.
    static var kilnPreferredColorScheme: ColorScheme? {
        kilnThemeMode.colorScheme
    }

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
