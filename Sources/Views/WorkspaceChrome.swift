import SwiftUI

struct WorkspaceIconButton: View {
    let icon: String
    let label: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Color.kilnAccent : Color.kilnTextSecondary)
                .frame(width: 30, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(WorkspaceButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

struct WorkspaceButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        HoverSurface(configuration: configuration, reduceMotion: reduceMotion)
    }

    private struct HoverSurface: View {
        let configuration: ButtonStyleConfiguration
        let reduceMotion: Bool
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(configuration.isPressed ? Color.kilnSurfaceHover : hovering ? Color.kilnSurfaceElevated : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        }
    }
}

struct ComposerSurface<Input: View, Controls: View>: View {
    var focused = false
    var dropTarget = false
    @ViewBuilder let input: () -> Input
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            input().frame(maxWidth: .infinity, alignment: .leading)
            controls()
        }
        .padding(14)
        .background(Color.kilnSurfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(dropTarget ? Color.kilnAccent : focused ? Color.kilnTextTertiary.opacity(0.65) : Color.kilnBorder,
                    lineWidth: dropTarget ? 2 : 1))
    }
}
