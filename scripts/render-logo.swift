#!/usr/bin/env swift
//
// Render the Kiln brand mark (the one in SidebarView: amber rounded square +
// flame.fill glyph) to a PNG, then build a full .iconset for .icns packaging.
// Run from the repo root:
//
//   swift scripts/render-logo.swift
//
// Outputs:
//   assets/logo.png                        1024x1024
//   Sources/App/Resources/AppIcon.icns     all macOS icon sizes
//
import AppKit

// Palette — keep in sync with Theme.swift (kilnAccent default + kilnBg).
let accent = NSColor(srgbRed: 0xF5/255.0, green: 0x9E/255.0, blue: 0x0B/255.0, alpha: 1)
let glyph  = NSColor(srgbRed: 0x0A/255.0, green: 0x0A/255.0, blue: 0x0B/255.0, alpha: 1)

/// Draw the mark at `size` px square. `cornerRadius` ratio ~0.22 mimics the
/// macOS app-icon silhouette so the big exports feel bundle-native, while
/// the in-app 22pt mark uses a tighter 6/22 ≈ 0.27. Close enough.
func renderMark(size: Int) -> NSImage {
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let image = NSImage(size: rect.size)
    image.lockFocus()
    defer { image.unlockFocus() }

    let radius = CGFloat(size) * 0.22
    let tile = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    accent.setFill()
    tile.fill()

    // Flame glyph, ~65% of tile width. SF Symbols API returns a templated
    // NSImage we tint by drawing into a color-masked layer.
    let glyphSize = CGFloat(size) * 0.62
    let config = NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .heavy)
    guard let flame = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
        fputs("flame.fill SF Symbol missing — need macOS 11+\n", stderr)
        exit(1)
    }
    let flameRect = NSRect(
        x: (CGFloat(size) - flame.size.width) / 2,
        y: (CGFloat(size) - flame.size.height) / 2,
        width: flame.size.width,
        height: flame.size.height
    )
    // Tint the glyph in its *own* image so `.sourceIn` only masks the
    // symbol's alpha. Doing the sourceIn directly on the tile context would
    // intersect with the tile's full-opacity alpha and fill the whole rect.
    let glyphCanvas = NSImage(size: flame.size)
    glyphCanvas.lockFocus()
    flame.draw(at: .zero, from: NSRect(origin: .zero, size: flame.size),
               operation: .sourceOver, fraction: 1.0)
    glyph.setFill()
    NSRect(origin: .zero, size: flame.size).fill(using: .sourceIn)
    glyphCanvas.unlockFocus()
    glyphCanvas.draw(in: flameRect)

    return image
}

func writePNG(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else {
        fputs("failed to encode \(path)\n", stderr); exit(1)
    }
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    do {
        try png.write(to: url)
        print("wrote \(path)")
    } catch {
        fputs("failed to write \(path): \(error)\n", stderr); exit(1)
    }
}

// 1024px hero for assets/logo.png + README.
let hero = renderMark(size: 1024)
writePNG(hero, to: "assets/logo.png")

// iconset for iconutil. macOS wants 16/32/64/128/256/512/1024 incl. @2x pairs.
let iconsetDir = ".build/Kiln.iconset"
try? FileManager.default.removeItem(atPath: iconsetDir)
try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]
for (px, name) in sizes {
    writePNG(renderMark(size: px), to: "\(iconsetDir)/\(name)")
}

// iconutil is a shell util; call it out.
let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", iconsetDir, "-o", "Sources/App/Resources/AppIcon.icns"]
try? task.run()
task.waitUntilExit()
if task.terminationStatus == 0 {
    print("wrote Sources/App/Resources/AppIcon.icns")
} else {
    fputs("iconutil failed\n", stderr); exit(1)
}
