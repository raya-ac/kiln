import Foundation
import Darwin

enum CodexModelDiscovery {
    struct Page: Decodable {
        let data: [Entry]
        let nextCursor: String?
    }
    struct Entry: Decodable {
        let model: String
        let displayName: String
        let description: String?
        let hidden: Bool?
        let supportedReasoningEfforts: [Effort]
        let contextWindow: Int?
        let serviceTiers: [ServiceTier]?
        let additionalSpeedTiers: [String]?
        struct ServiceTier: Decodable { let id: String; let description: String? }
        struct Effort: Decodable { let reasoningEffort: String }
    }

    static func descriptors(from pages: [Page]) -> [ModelDescriptor] {
        var seen = Set<String>()
        return pages.flatMap(\.data).compactMap { entry in
            guard entry.hidden != true, let model = AgentModel(rawValue: entry.model), model.provider == .codex,
                  seen.insert(entry.model).inserted else { return nil }
            return ModelDescriptor(model: model, displayName: entry.displayName,
                description: entry.description ?? "Codex model", contextWindow: entry.contextWindow ?? 272_000,
                efforts: entry.supportedReasoningEfforts.map(\.reasoningEffort),
                fastModeTier: entry.serviceTiers?.first { ["fast", "priority"].contains($0.id) }?.id
                    ?? entry.additionalSpeedTiers?.first { ["fast", "priority"].contains($0) },
                fastModeDescription: entry.serviceTiers?.first { ["fast", "priority"].contains($0.id) }?.description)
        }
    }

    /// Discovery only: no threads, turns, tools, or user prompts are started.
    static func fetch(executable: String = CodexCLI.executablePath) async throws -> [ModelDescriptor] {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = (executable == "/usr/bin/env" ? ["codex"] : []) + ["app-server", "--listen", "stdio://"]
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
            process.environment = environment
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
            defer {
                try? input.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
                let cleanup = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: cleanup)
                process.waitUntilExit()
                timeout.cancel()
                cleanup.cancel()
                try? output.fileHandleForReading.close()
            }
            func send(_ object: [String: Any]) throws {
                var data = try JSONSerialization.data(withJSONObject: object)
                data.append(10)
                try input.fileHandleForWriting.write(contentsOf: data)
            }
            var buffer = Data()
            func response(id: Int) throws -> Data {
                while true {
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = buffer.prefix(upTo: newline)
                        buffer.removeSubrange(...newline)
                        guard let json = try JSONSerialization.jsonObject(with: line) as? [String: Any], json["id"] as? Int == id else { continue }
                        guard json["error"] == nil, let result = json["result"] else { throw CocoaError(.fileReadUnknown) }
                        return try JSONSerialization.data(withJSONObject: result)
                    }
                    let chunk = output.fileHandleForReading.availableData
                    guard !chunk.isEmpty, buffer.count + chunk.count <= 2 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
                    buffer.append(chunk)
                }
            }
            try send(["id": 0, "method": "initialize", "params": ["clientInfo": ["name": "kiln", "title": "Kiln", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"]]])
            _ = try response(id: 0)
            try send(["method": "initialized", "params": [:]])
            var pages: [Page] = []
            for id in 1...20 {
                var params: [String: Any] = ["limit": 100, "includeHidden": false]
                if let cursor = pages.last?.nextCursor { params["cursor"] = cursor }
                try send(["id": id, "method": "model/list", "params": params])
                let page = try JSONDecoder().decode(Page.self, from: response(id: id))
                pages.append(page)
                if page.nextCursor == nil {
                    let result = descriptors(from: pages)
                    guard !result.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    return result
                }
            }
            throw CocoaError(.fileReadCorruptFile)
        }.value
    }
}
