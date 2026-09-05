import SwiftUI
import AppKit

struct ModelBrandIcon: View {
    let brand: ModelBrand
    let size: CGFloat

    var body: some View {
        Group {
            switch brand {
            case .chatgpt:
                OpenAIKnotMark()
            case .codex:
                Image(systemName: "terminal").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Official, unmodified OpenAI assets. Keep the mark monochrome in either appearance.
struct OpenAIKnotMark: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: colorScheme == .dark ? ModelBrandAssets.white : ModelBrandAssets.black)
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }
}

@MainActor
enum ModelBrandAssets {
    static let white = load("white")
    static let black = load("black")

    private static func load(_ color: String) -> NSImage {
        guard let url = Bundle.module.url(forResource: "OpenAI-\(color)-monoblossom", withExtension: "png", subdirectory: "brands"),
              let image = NSImage(contentsOf: url) else { return NSImage() }
        return image
    }
}
