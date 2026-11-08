import SwiftUI

struct BrandTapSequence {
    private var count = 0
    private var lastTap = Date.distantPast
    mutating func tap(now: Date = .now) -> Bool {
        let elapsed = now.timeIntervalSince(lastTap)
        count = elapsed >= 0 && elapsed < 3 ? count + 1 : 1
        lastTap = now
        guard count == 7 else { return false }
        count = 0
        return true
    }
}

struct WorkspaceIconButton: View {
    let icon: String
    let label: String
    var active = false
    var identifier = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .accessibilityHidden(true)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Color.kilnAccent : Color.kilnTextSecondary)
                .frame(width: 30, height: 30)
                .background(active ? Color.kilnAccentMuted.opacity(0.5) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(WorkspaceButtonStyle())
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier.isEmpty ? label : identifier)
        .accessibilityValue(active ? "Selected" : "")
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var focused = false
    var dropTarget = false
    @ViewBuilder let input: () -> Input
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            input().frame(maxWidth: .infinity, alignment: .leading)
            controls()
        }
        .padding(16)
        .background(Color.kilnSurfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(dropTarget ? Color.kilnAccent : focused ? Color.kilnAccent.opacity(0.6) : Color.kilnBorder,
                    lineWidth: dropTarget ? 2 : 1))
        .shadow(color: .black.opacity(focused ? 0.12 : 0.06), radius: 12, y: 4)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: focused)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: dropTarget)
    }
}

struct ToolShelfTabs: View {
    @Binding var selection: ToolShelfTab
    var body: some View {
        HStack(spacing: 3) {
            ForEach(ToolShelfTab.allCases) { tab in
                Button { selection = tab } label: {
                    Label(tab.rawValue, systemImage: tab.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selection == tab ? Color.kilnText : Color.kilnTextSecondary)
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(selection == tab ? Color.kilnSurfaceHover : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(WorkspaceButtonStyle())
                    .accessibilityLabel(tab.rawValue)
                    .accessibilityValue(selection == tab ? "Selected" : "")
            }
        }.padding(3).background(Color.kilnSurface).clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
