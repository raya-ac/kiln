import Foundation

enum CodexCLI {
    static var executablePath: String {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/env"
    }

    static func output(_ arguments: [String], executable: String? = nil, command: String = "codex") async throws -> Data {
        try await Task.detached {
            let process = Process()
            let path = executable ?? executablePath
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = (path == "/usr/bin/env" ? [command] : []) + arguments
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
            return data
        }.value
    }
}
