import SwiftUI
import AppKit

/// Compact chip that sits above the composer showing how many files have
/// changed in the session's workdir since the last clean state. Clicking
/// opens a popover with the actual list — hover a row to see the file's
/// path, click it to open the diff in the existing DiffSheet.
///
/// Intentionally low-chrome: a single pill in the bar, no row when the
/// workdir is clean or the session isn't in a git repo. The whole point
/// is being visible only when there's something to see.
struct WorkdirActivityChip: View {
    @EnvironmentObject var store: AppStore
    @State private var showPopover = false

    private var changes: [ChangedFile] {
        guard let id = store.activeSessionId else { return [] }
        return store.workdirChanges[id] ?? []
    }

    var body: some View {
        if !changes.isEmpty {
            HStack {
                Button {
                    showPopover.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.badge.gearshape")
                            .font(.system(size: 10, weight: .semibold))
                        Text("\(changes.count) file\(changes.count == 1 ? "" : "s") changed")
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(Color.kilnAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.kilnAccent.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showPopover, arrowEdge: .top) {
                    WorkdirActivityList(changes: changes)
                        .environmentObject(store)
                        .frame(width: 380)
                        .frame(maxHeight: 320)
                }

                Spacer()

                // Quick "refresh now" in case Claude ran something outside
                // our event stream (e.g. user ran a git op in Terminal).
                Button {
                    if let id = store.activeSessionId {
                        store.refreshWorkdirActivity(id)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.kilnTextSecondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("Re-scan workdir")
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 2)
        }
    }
}

/// The popover body. One row per changed file, status letter on the left,
/// path on the right. Hover reveals the full path (which may be long);
/// click opens the diff.
private struct WorkdirActivityList: View {
    @EnvironmentObject var store: AppStore
    let changes: [ChangedFile]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Changed files")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.kilnTextSecondary)
                Spacer()
                Button("Open all in diff") {
                    openFullDiff()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(changes) { file in
                        WorkdirActivityRow(file: file) {
                            openFileDiff(file)
                        }
                    }
                }
            }
        }
    }

    private func openFullDiff() {
        guard let dir = store.activeSession?.workDir,
              let d = GitQuickCommit.diff(workDir: dir) else { return }
        store.diffSheetContent = d.isEmpty ? "# No changes — working tree is clean.\n" : d
    }

    private func openFileDiff(_ file: ChangedFile) {
        guard let dir = store.activeSession?.workDir else { return }
        if let d = WorkdirActivity.diff(dir, file: file.path), !d.isEmpty {
            store.diffSheetContent = d
        } else {
            // Paths we can't diff (binary, non-UTF8) — surface gracefully
            // instead of flashing an empty sheet.
            ToastCenter.shared.show("No diff available for \(file.path)", kind: .info)
        }
    }
}

private struct WorkdirActivityRow: View {
    let file: ChangedFile
    let onTap: () -> Void

    @State private var hovered = false

    private var statusColor: Color {
        switch file.shortStatus {
        case "M": return .orange
        case "A", "?": return .green
        case "D": return .red
        case "R": return .blue
        default:   return .gray
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Text(file.shortStatus)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusColor)
                    .frame(width: 18)
                Text(file.path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.kilnText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.kilnTextSecondary.opacity(hovered ? 1.0 : 0.0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(hovered ? Color.kilnAccent.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(file.path)
    }
}
