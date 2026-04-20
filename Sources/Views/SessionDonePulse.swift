import SwiftUI

// MARK: - Session "done" pulse
//
// Small animated green dot shown in the sidebar when a background session
// finishes generating while the user is looking at a different session.
// Clears the moment the session is selected — see AppStore.activeSessionId.didSet.

struct SessionDonePulse: View {
    @State private var scale: CGFloat = 1.0

    var body: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 6, height: 6)
            .overlay(
                Circle()
                    .stroke(Color.green.opacity(0.5), lineWidth: 1.5)
                    .scaleEffect(scale)
                    .opacity(2.0 - scale)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    scale = 2.2
                }
            }
            .help("New response ready")
    }
}

// MARK: - Press feedback button style
//
// Applies a quick scale + opacity flash when pressed. Apply globally by
// wrapping a Button with `.buttonStyle(KilnPressStyle())`.

struct KilnPressStyle: ButtonStyle {
    var scaleAmount: CGFloat = 0.92
    var dimAmount: Double = 0.7

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scaleAmount : 1.0)
            .opacity(configuration.isPressed ? dimAmount : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
