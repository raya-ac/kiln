import Foundation
import SwiftUI

/// Transient notification for quick feedback — "commit succeeded",
/// "link copied", etc. Deliberately minimal: one toast at a time,
/// auto-dismisses, queues if something else is showing.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let kind: Kind
    let duration: TimeInterval

    enum Kind: Equatable { case info, success, error }
}

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()
    @Published private(set) var current: Toast?
    private var queue: [Toast] = []
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String, kind: Toast.Kind = .info, duration: TimeInterval = 2.4) {
        let t = Toast(message: message, kind: kind, duration: duration)
        if current == nil {
            present(t)
        } else {
            queue.append(t)
        }
    }

    func dismissCurrent() {
        dismissTask?.cancel()
        current = nil
        if !queue.isEmpty {
            present(queue.removeFirst())
        }
    }

    private func present(_ toast: Toast) {
        current = toast
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(toast.duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Only auto-dismiss if we're still the active toast —
                // otherwise a tap-to-dismiss between sleep and wake
                // would pop the *next* queued toast prematurely.
                guard self?.current?.id == toast.id else { return }
                self?.dismissCurrent()
            }
        }
    }
}

/// Overlay view — attach once at the root of the window.
struct ToastOverlay: View {
    @ObservedObject var center = ToastCenter.shared

    var body: some View {
        VStack {
            Spacer()
            if let t = center.current {
                HStack(spacing: 8) {
                    Image(systemName: icon(for: t.kind))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color(for: t.kind))
                    Text(t.message)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.kilnText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.kilnSurfaceElevated)
                        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.kilnBorderSubtle, lineWidth: 1)
                )
                .onTapGesture { center.dismissCurrent() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 24)
            }
        }
        .animation(.easeOut(duration: 0.2), value: center.current)
        .allowsHitTesting(center.current != nil)
    }

    private func icon(for kind: Toast.Kind) -> String {
        switch kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private func color(for kind: Toast.Kind) -> Color {
        switch kind {
        case .info: return Color.kilnAccent
        case .success: return Color.kilnSuccess
        case .error: return Color.kilnError
        }
    }
}
