import XCTest
@testable import Kiln

final class SessionContinuityTests: XCTestCase {
    private func executable(_ script: String, directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("fake-codex")
        try Data(script.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file.path
    }

    @MainActor func testFollowUpResumesSameThreadAfterServiceRecreation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let thread = UUID().uuidString.lowercased()
        let session = UUID().uuidString
        let path = try executable("""
        #!/bin/sh
        cat >/dev/null
        case " $* " in *" resume "*) result=continued;; *) result=new;; esac
        printf '%s\\n' '{"type":"thread.started","thread_id":"\(thread)"}'
        printf '%s\\n' '{"type":"turn.started"}'
        printf '{"type":"item.completed","item":{"type":"agent_message","text":"%s"}}\\n' "$result"
        printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":9999999,"output_tokens":10}}'
        """, directory: directory)
        let first = AgentService(executablePath: path)
        defer { first.forgetThread(for: session) }
        var text = ""
        await first.sendMessage(sessionId: session, message: "first", model: .gpt55, workDir: directory.path) {
            if case .textDelta(let value) = $0 { text += value }
        }
        XCTAssertEqual(text, "new")
        let second = AgentService(executablePath: path)
        XCTAssertEqual(second.threadID(for: session), thread)
        text = ""
        var context: ContextUsage?
        await second.sendMessage(sessionId: session, message: "follow-up", model: .gpt55, workDir: directory.path) {
            if case .textDelta(let value) = $0 { text += value }
            if case .contextUsage(let value) = $0 { context = value }
        }
        XCTAssertEqual(text, "continued")
        XCTAssertEqual(second.threadID(for: session), thread)
        XCTAssertNil(context, "Aggregate exec usage must never masquerade as context")
    }

    func testCompactionUsesExistingThreadAndWaitsPastAcknowledgement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let thread = UUID().uuidString.lowercased()
        let path = try executable("""
        #!/bin/sh
        IFS= read -r request
        printf '%s\\n' '{"id":0,"result":{}}'
        IFS= read -r notification
        IFS= read -r request
        case "$request" in *resume*) ;; *) exit 2;; esac
        case "$request" in *\(thread)*) ;; *) exit 3;; esac
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r request
        case "$request" in *compact*) ;; *) exit 4;; esac
        case "$request" in *\(thread)*) ;; *) exit 5;; esac
        printf '%s\\n' '{"id":2,"result":{}}'
        printf '%s\\n' '{"method":"turn/started","params":{"threadId":"\(thread)","turn":{"id":"compact-turn"}}}'
        printf '%s\\n' '{"method":"item/completed","params":{"threadId":"\(thread)","turnId":"compact-turn","item":{"type":"contextCompaction"}}}'
        printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"\(thread)","turn":{"id":"compact-turn","status":"completed"}}}'
        """, directory: directory)
        try await CodexThreadCompactor.compact(threadID: thread, executable: path, workDir: directory.path)
    }
}
