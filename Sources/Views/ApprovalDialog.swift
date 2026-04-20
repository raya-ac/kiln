import SwiftUI

/// PreToolUse approval sheet. Renders the first `PendingApproval` in the
/// store's queue; Approve/Deny resolve the continuation that the hook is
/// blocked on. Y/N keyboard shortcuts mirror the buttons.
///
/// The sheet is presented from `ContentView` whenever `pendingApprovals` is
/// non-empty. Subsequent approvals in the queue pop into the same sheet as
/// the user works through them.
struct ApprovalDialog: View {
    @EnvironmentObject var store: AppStore
    let approval: PendingApproval

    @State private var reason: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .foregroundColor(Color.kilnAccent)
                    .font(.system(size: 16, weight: .semibold))
                Text("Tool approval required")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color.kilnText)
                Spacer()
                if store.pendingApprovals.count > 1 {
                    Text("+\(store.pendingApprovals.count - 1) waiting")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.kilnTextTertiary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.kilnSurfaceElevated)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider().background(Color.kilnBorderSubtle)

            // Body
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TOOL")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color.kilnTextTertiary)
                        .kerning(0.8)
                    Text(approval.toolName)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color.kilnText)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("INPUT")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color.kilnTextTertiary)
                        .kerning(0.8)
                    ScrollView {
                        Text(approval.toolInputJSON)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Color.kilnText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .frame(maxHeight: 280)
                    .background(Color.kilnSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.kilnBorderSubtle, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("DENY REASON (OPTIONAL)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color.kilnTextTertiary)
                        .kerning(0.8)
                    TextField("Passed to Claude if you deny", text: $reason)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(Color.kilnText)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color.kilnSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.kilnBorderSubtle, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(20)

            Divider().background(Color.kilnBorderSubtle)

            // Footer buttons
            HStack(spacing: 10) {
                Spacer()
                Button {
                    store.respondToApproval(
                        id: approval.id,
                        approve: false,
                        reason: reason.isEmpty ? "Denied by user" : reason
                    )
                } label: {
                    HStack(spacing: 6) {
                        Text("Deny").font(.system(size: 13, weight: .medium))
                        Text("N").font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color.kilnTextTertiary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.kilnSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .foregroundColor(Color.kilnText)
                    .background(Color.kilnSurfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.kilnBorder, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: [])

                Button {
                    store.respondToApproval(id: approval.id, approve: true)
                } label: {
                    HStack(spacing: 6) {
                        Text("Approve").font(.system(size: 13, weight: .semibold))
                        Text("Y").font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color.black.opacity(0.6))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.black.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .foregroundColor(.black)
                    .background(Color.kilnAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560)
        .background(Color.kilnBg)
    }
}
