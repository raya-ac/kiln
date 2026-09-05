import Foundation
import Darwin

struct CodexCompactionProgress {
    let threadID: String
    var turnID: String?
    var compacted = false
    var complete = false

    mutating func consume(_ json: [String: Any]) throws {
        let params = json["params"] as? [String: Any] ?? [:]
        guard params["threadId"] as? String == threadID else { return }
        let turn = params["turn"] as? [String: Any] ?? [:]
        switch json["method"] as? String {
        case "turn/started": turnID = turn["id"] as? String
        case "item/completed":
            let item = params["item"] as? [String: Any] ?? [:]
            if item["type"] as? String == "contextCompaction", params["turnId"] as? String == turnID { compacted = true }
        case "thread/compacted": compacted = true
        case "turn/completed":
            guard let turnID, turn["id"] as? String == turnID else { return }
            guard turn["status"] as? String == "completed", compacted else { throw CocoaError(.fileWriteUnknown) }
            complete = true
        case "error": throw CocoaError(.fileWriteUnknown)
        default: break
        }
    }
}

enum CodexThreadCompactor {
    static func compact(threadID: String, executable: String, workDir: String) async throws {
        guard UUID(uuidString: threadID) != nil else { throw CocoaError(.validationMissingMandatoryProperty) }
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = (executable == "/usr/bin/env" ? ["codex"] : []) + ["app-server", "--listen", "stdio://"]
            process.currentDirectoryURL = URL(fileURLWithPath: workDir)
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            let killTimeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
            DispatchQueue.global().asyncAfter(deadline: .now() + 122, execute: killTimeout)
            defer {
                try? input.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
                let cleanup = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: cleanup)
                process.waitUntilExit()
                cleanup.cancel(); timeout.cancel(); killTimeout.cancel()
                try? output.fileHandleForReading.close()
            }
            var buffer = Data()
            var progress = CodexCompactionProgress(threadID: threadID)
            func send(_ value: [String: Any]) throws {
                var data = try JSONSerialization.data(withJSONObject: value)
                data.append(10)
                try input.fileHandleForWriting.write(contentsOf: data)
            }
            func next() throws -> [String: Any] {
                while true {
                    if let newline = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<newline])
                        buffer.removeSubrange(...newline)
                        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                        try progress.consume(json)
                        return json
                    }
                    let data = output.fileHandleForReading.availableData
                    guard !data.isEmpty, buffer.count + data.count <= 32_000_000 else { throw CocoaError(.fileReadUnknown) }
                    buffer.append(data)
                }
            }
            func response(_ id: Int) throws {
                while true {
                    let json = try next()
                    guard json["id"] as? Int == id else { continue }
                    guard json["error"] == nil else { throw CocoaError(.fileWriteUnknown) }
                    return
                }
            }
            try send(["id": 0, "method": "initialize", "params": ["clientInfo": ["name": "kiln", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"]]])
            try response(0)
            try send(["method": "initialized", "params": [:]])
            try send(["id": 1, "method": "thread/resume", "params": ["threadId": threadID]])
            try response(1)
            try send(["id": 2, "method": "thread/compact/start", "params": ["threadId": threadID]])
            try response(2)
            while !progress.complete { _ = try next() }
        }.value
    }
}
