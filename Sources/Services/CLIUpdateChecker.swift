import Foundation

enum CLIInstallMethod: String, Sendable {
    case homebrew = "Homebrew", cask = "Homebrew cask", npm, pnpm, bun
    case standalone = "Standalone", custom = "Custom installation"

    static func detect(provider: ModelProvider, resolvedPath: String) -> Self {
        if resolvedPath.contains("/Caskroom/\(provider.rawValue)/") { return .cask }
        if resolvedPath.contains("/Cellar/\(provider.rawValue)/") { return .homebrew }
        if resolvedPath.contains("/node_modules/") {
            if resolvedPath.contains("/pnpm/") || resolvedPath.contains("/.pnpm/") { return .pnpm }
            if resolvedPath.contains("/.bun/") { return .bun }
            return .npm
        }
        if provider == .codex && resolvedPath.contains("/.codex/packages/standalone/") { return .standalone }
        if provider == .opencode && resolvedPath.contains("/.opencode/bin/") { return .standalone }
        return .custom
    }

    func updateCommand(provider: ModelProvider, executable: String) -> String? {
        let package = provider == .codex ? "@openai/codex" : "opencode-ai"
        switch self {
        case .homebrew: return "brew upgrade \(provider.rawValue)"
        case .cask: return "brew upgrade --cask \(provider.rawValue)"
        case .npm: return "npm install -g \(package)@latest"
        case .pnpm: return "pnpm add -g \(package)@latest"
        case .bun: return "bun add -g \(package)@latest"
        case .standalone:
            let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
            return quoted + (provider == .codex ? " update" : " upgrade")
        case .custom: return nil
        }
    }
}

enum CLIReleaseSource: Sendable {
    case codex, opencode, brew(ModelProvider, cask: Bool)

    var url: URL {
        switch self {
        case .codex: return URL(string: "https://registry.npmjs.org/@openai/codex/latest")!
        case .opencode: return URL(string: "https://api.github.com/repos/anomalyco/opencode/releases/latest")!
        case .brew(let provider, let cask):
            return URL(string: "https://formulae.brew.sh/api/\(cask ? "cask" : "formula")/\(provider.rawValue).json")!
        }
    }

    func parse(_ data: Data) throws -> CLIVersion {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let raw: String?
        switch self {
        case .codex: raw = json?["version"] as? String
        case .opencode:
            guard json?["prerelease"] as? Bool == false, json?["draft"] as? Bool == false else { throw CLIUpdateError.invalidRelease }
            raw = json?["tag_name"] as? String
        case .brew(_, let cask):
            raw = cask ? json?["version"] as? String : (json?["versions"] as? [String: Any])?["stable"] as? String
        }
        guard let raw, let version = CLIVersion(raw), version.prerelease.isEmpty else { throw CLIUpdateError.invalidRelease }
        return version
    }

    func fetch(using session: URLSession) async throws -> CLIVersion {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("Kiln-CLI-Update-Checker", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw CLIUpdateError.invalidRelease }
        guard http.statusCode == 200 else { throw CLIUpdateError.http(http.statusCode) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 256 * 1024 else { throw CLIUpdateError.invalidRelease }
            data.append(byte)
        }
        return try parse(data)
    }
}

enum CLIUpdateError: LocalizedError {
    case invalidRelease, http(Int), invalidVersion
    var errorDescription: String? {
        switch self {
        case .invalidRelease: "The release service returned an invalid version."
        case .http(let code): code == 403 || code == 429 ? "Release checks are rate-limited. Try again later." : "Release service unavailable (HTTP \(code))."
        case .invalidVersion: "The installed CLI did not report a recognizable version."
        }
    }
}

struct CLIUpdateResult: Identifiable, Sendable {
    let provider: ModelProvider
    var id: String { provider.rawValue }
    var executable: String?
    var method: CLIInstallMethod = .custom
    var installed: CLIVersion?
    var latest: CLIVersion?
    var available: CLIVersion?
    var problem: String?
    var checkedAt: Date?

    var status: String {
        if checkedAt == nil { return "Not checked" }
        if problem != nil { return "Check failed" }
        guard executable != nil else { return "Not installed" }
        guard let installed, let latest, let available else { return "Unknown" }
        if installed < available { return "Update available" }
        if installed < latest { return "Waiting for Homebrew" }
        if latest < installed { return "Newer than stable" }
        return "Up to date"
    }
    var hasUpdate: Bool {
        guard problem == nil, let installed, let available else { return false }
        return installed < available
    }
    var command: String? {
        guard hasUpdate, let executable else { return nil }
        return method.updateCommand(provider: provider, executable: executable)
    }
    var releaseURL: URL {
        URL(string: provider == .codex ? "https://github.com/openai/codex/releases/latest" : "https://github.com/anomalyco/opencode/releases/latest")!
    }
    var instructionsURL: URL {
        URL(string: provider == .codex ? "https://developers.openai.com/codex/cli/" : "https://opencode.ai/docs/cli/#upgrade")!
    }
}

enum CLIUpdateInspector {
    static func executable(for provider: ModelProvider) -> String? {
        let preferred = provider == .codex ? CodexCLI.executablePath : OpenCodeProtocol.executablePath
        if preferred != "/usr/bin/env" { return preferred }
        let home = NSHomeDirectory()
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "\(home)/.local/bin", "\(home)/.cargo/bin", "\(home)/.bun/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return paths.map { $0 + "/" + provider.rawValue }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func inspect(_ provider: ModelProvider) async -> CLIUpdateResult {
        var result = CLIUpdateResult(provider: provider)
        result.executable = executable(for: provider)
        if let executable = result.executable {
            result.method = .detect(provider: provider, resolvedPath: URL(fileURLWithPath: executable).resolvingSymlinksInPath().path)
            do {
                let data = try await CodexCLI.output(["--version"], executable: executable, command: provider.rawValue,
                    environment: ["OPENCODE_DISABLE_AUTOUPDATE": "1"])
                guard let version = CLIVersion(String(decoding: data, as: UTF8.self)) else { throw CLIUpdateError.invalidVersion }
                result.installed = version
            } catch { result.problem = "Installed version: \(error.localizedDescription)" }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            result.latest = try await (provider == .codex ? CLIReleaseSource.codex : .opencode).fetch(using: session)
            if result.method == .homebrew || result.method == .cask {
                result.available = try await CLIReleaseSource.brew(provider, cask: result.method == .cask).fetch(using: session)
            } else { result.available = result.latest }
        } catch {
            result.problem = [result.problem, "Release check: \(error.localizedDescription)"].compactMap { $0 }.joined(separator: "\n")
        }
        result.checkedAt = Date()
        return result
    }
}

@MainActor
final class CLIUpdateChecker: ObservableObject {
    static let shared = CLIUpdateChecker()
    @Published private(set) var results = [CLIUpdateResult(provider: .codex), CLIUpdateResult(provider: .opencode)]
    @Published private(set) var isChecking = false
    @Published private(set) var checkedAt: Date?
    private let inspect: @Sendable (ModelProvider) async -> CLIUpdateResult

    init(inspect: @escaping @Sendable (ModelProvider) async -> CLIUpdateResult = CLIUpdateInspector.inspect) {
        self.inspect = inspect
    }

    func check(force: Bool = true) async {
        guard !isChecking else { return }
        if !force, let checkedAt, Date().timeIntervalSince(checkedAt) < 3600,
           results.allSatisfy({ $0.problem == nil }) { return }
        isChecking = true
        defer { isChecking = false }
        await withTaskGroup(of: CLIUpdateResult.self) { group in
            for provider in [ModelProvider.codex, .opencode] {
                group.addTask { [inspect] in await inspect(provider) }
            }
            for await result in group {
                if let index = results.firstIndex(where: { $0.provider == result.provider }) { results[index] = result }
            }
        }
        checkedAt = Date()
    }
}
