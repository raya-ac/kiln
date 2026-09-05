import SwiftUI
import AppKit

struct CLIUpdatesView: View {
    @ObservedObject var checker: CLIUpdateChecker = .shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    if let date = checker.checkedAt {
                        Text("Checked \(date.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 11)).foregroundStyle(Color.kilnTextSecondary)
                    }
                    Spacer()
                    if checker.isChecking { ProgressView().controlSize(.small) }
                    Button {
                        Task { await checker.check() }
                    } label: {
                        Label("Check now", systemImage: "arrow.clockwise")
                    }
                    .disabled(checker.isChecking)
                    .help("Check installed CLI versions and latest stable releases")
                }
                ForEach(checker.results) { result in
                    CLIUpdateRow(result: result, checking: checker.isChecking)
                    if result.provider == .codex { Divider() }
                }
            }
            .padding(24)
        }
        .task { await checker.check(force: false) }
    }
}

private struct CLIUpdateRow: View {
    let result: CLIUpdateResult
    let checking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ModelBrandIcon(brand: result.provider == .codex ? .chatgpt : .codex, size: 22)
                Text(result.provider.label).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(checking ? "Checking..." : result.status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(result.problem != nil ? Color.kilnError : result.hasUpdate ? Color.kilnAccent : Color.kilnTextSecondary)
            }
            HStack(alignment: .top, spacing: 24) {
                version("Installed", result.installed?.text ?? (result.checkedAt == nil ? "-" : result.executable == nil ? "Not found" : "Unknown"))
                version("Latest stable", result.latest?.text ?? "-")
                if result.method == .homebrew || result.method == .cask {
                    version("Homebrew", result.available?.text ?? "-")
                }
                Spacer(minLength: 0)
            }
            if let executable = result.executable {
                Text("\(result.method.rawValue) · \(executable)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.kilnTextSecondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if let problem = result.problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(Color.kilnError)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let command = result.command {
                HStack(alignment: .top) {
                    Text(command).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        ToastCenter.shared.show("Update command copied")
                    } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy update command").accessibilityLabel("Copy \(result.provider.label) update command")
                }
            }
            HStack(spacing: 16) {
                Link(destination: result.releaseURL) { Label("Release notes", systemImage: "arrow.up.right") }
                Link(destination: result.instructionsURL) { Label("Installation", systemImage: "arrow.up.right") }
            }
            .font(.system(size: 11))
        }
        .foregroundStyle(Color.kilnText)
        .buttonStyle(.borderless)
    }

    private func version(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundStyle(Color.kilnTextSecondary)
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
