import AppKit

// MARK: - Dock icon live-tinting
//
// The bundled .icns is signed and can't be changed at runtime, so Finder /
// Launchpad keep the default amber mark. The Dock and ⌘Tab switcher,
// however, read from `NSApp.applicationIconImage` — we can swap that at
// will to match the user's accent color in settings.
//
// Mirrors scripts/render-logo.swift but is driven by a dynamic color and
// called from AppStore whenever `settings.accentHex` changes.

enum DockIconRenderer {
    /// Render the Kiln mark at 512pt (Dock size is capped there anyway)
    /// using `accent` as the tile color. The glyph stays near-black so
    /// contrast holds regardless of how light the accent is; darker
    /// accents still read fine because the glyph is much smaller than the
    /// tile.
    static func render(accent: NSColor, size: CGFloat = 512) -> NSImage {
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let image = NSImage(size: rect.size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let radius = size * 0.22
        let tile = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        accent.setFill()
        tile.fill()

        // Glyph color: pick dark-on-light or light-on-dark based on the
        // accent's luminance. Pure black/white read cleaner than any fixed
        // brand color once the accent hue varies freely.
        let glyphColor = contrastingGlyphColor(for: accent)

        let glyphSize = size * 0.62
        let config = NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .heavy)
        guard let flame = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else {
            return image
        }

        // Render the glyph into its own canvas first so `.sourceIn` only
        // masks the symbol's alpha, not the full tile.
        let glyphCanvas = NSImage(size: flame.size)
        glyphCanvas.lockFocus()
        flame.draw(at: .zero, from: NSRect(origin: .zero, size: flame.size),
                   operation: .sourceOver, fraction: 1.0)
        glyphColor.setFill()
        NSRect(origin: .zero, size: flame.size).fill(using: .sourceIn)
        glyphCanvas.unlockFocus()

        let flameRect = NSRect(
            x: (size - flame.size.width) / 2,
            y: (size - flame.size.height) / 2,
            width: flame.size.width,
            height: flame.size.height
        )
        glyphCanvas.draw(in: flameRect)

        return image
    }

    /// Push a freshly rendered icon onto the Dock. Safe to call off the
    /// main actor — AppKit marshals the assignment internally, but we
    /// jump to main anyway to keep semantics clear.
    @MainActor
    static func apply(accent: NSColor) {
        let img = render(accent: accent)
        NSApp.applicationIconImage = img
    }

    /// Relative-luminance check per WCAG. Used only to pick black vs
    /// white for the glyph — we don't need more precision than that.
    private static func contrastingGlyphColor(for color: NSColor) -> NSColor {
        // Convert into a known colorspace before extracting components;
        // NSColor initialized via srgbRed: already sits there but settings
        // colors that round-trip through Color() may not.
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        // Gamma-correct each channel
        func lin(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let l = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        return l > 0.55
            ? NSColor(srgbRed: 0x0A/255, green: 0x0A/255, blue: 0x0B/255, alpha: 1)
            : NSColor(srgbRed: 0xFA/255, green: 0xFA/255, blue: 0xF9/255, alpha: 1)
    }
}

// MARK: - Hex parsing for NSColor

extension NSColor {
    /// Parse "#F59E0B" / "F59E0B" / "0xF59E0B" into an sRGB NSColor.
    /// Falls back to the default amber on malformed input so we never
    /// crash the app icon off the dock.
    convenience init(kilnHexString s: String) {
        var hex = s.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex = String(hex.dropFirst()) }
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = String(hex.dropFirst(2)) }
        let v: UInt = UInt(hex, radix: 16) ?? 0xF59E0B
        self.init(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }
}
