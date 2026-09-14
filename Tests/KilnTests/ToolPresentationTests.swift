import XCTest
@testable import Kiln

final class ToolPresentationTests: XCTestCase {
    func testRepeatedProviderIDsAreIsolatedByResponse() {
        let first = ToolPresentation.disclosureID(messageID: "legacy-first", toolID: "item_3")
        let second = ToolPresentation.disclosureID(messageID: "legacy-second", toolID: "item_3")
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(ToolPresentation.disclosureID(messageID: "a:b", toolID: "c"),
                          ToolPresentation.disclosureID(messageID: "a", toolID: "b:c"))
    }

    func testLiveAndCompletedResponseUseTheSameScope() {
        let requestID = UUID().uuidString
        let live = ToolPresentation.assistantMessageID(userID: requestID)
        let final = ChatMessage(id: ToolPresentation.assistantMessageID(userID: requestID), role: .assistant, blocks: [])
        XCTAssertEqual(ToolPresentation.disclosureID(messageID: live, toolID: "item_0"),
                       ToolPresentation.disclosureID(messageID: final.id, toolID: "item_0"))
    }

    private func call(_ id: String = "call-1", done: Bool = false, result: String? = nil,
                      error: Bool = false, start: Date? = nil, end: Date? = nil) -> ToolUseBlock {
        .init(id: id, name: "exec_command", input: "{\"command\":\"pwd\"}", isDone: done,
              result: result, isError: error, startedAt: start, completedAt: end)
    }

    func testPendingRequiresAnActiveRunWithoutAStartReceipt() {
        XCTAssertEqual(ToolPresentation(tool: call(), live: true).status, .pending)
        XCTAssertEqual(ToolPresentation(tool: call(), live: false).status, .unconfirmed)
    }

    func testInputBlockStopDoesNotMeanExecutionSucceeded() {
        let tool = call(done: true, start: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(ToolPresentation(tool: tool, live: true).status, .running)
        XCTAssertEqual(ToolPresentation(tool: tool, live: false).status, .unconfirmed)
    }

    func testEmptyResultIsACompletionReceipt() {
        XCTAssertEqual(ToolPresentation(tool: call(result: ""), live: true).status, .success)
        XCTAssertEqual(ToolPresentation(tool: call(end: Date()), live: false).status, .success)
    }

    func testFailureWinsEvenWhenDoneOrStillStreaming() {
        for live in [true, false] {
            XCTAssertEqual(ToolPresentation(tool: call(done: true, result: "denied", error: true), live: live).status, .failure)
        }
    }

    func testDurationNeedsOrderedReceipts() {
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertNil(ToolPresentation(tool: call(start: start), live: true).duration)
        XCTAssertNil(ToolPresentation(tool: call(start: start, end: start.addingTimeInterval(-1)), live: false).duration)
        XCTAssertEqual(ToolPresentation(tool: call(start: start, end: start.addingTimeInterval(3)), live: false).duration, 3)
    }

    func testUpdatedCallsKeepIdentityAndOriginalPosition() {
        let calls = ToolPresentation.uniqueCalls([call("a"), call("b"), call("a", result: "ok")])
        XCTAssertEqual(calls.map(\.id), ["a", "b"])
        XCTAssertEqual(calls.first?.result, "ok")
    }

    func testAdjacentToolsGroupWithoutMovingProseOrReasoning() {
        let message = ChatMessage(id: "message", role: .assistant, blocks: [
            .text("Before"), .toolUse(call("a")), .toolUse(call("b")),
            .thinking("Summary"), .toolUse(call("c")), .text("After")
        ])
        let rows = ToolTranscriptRow.rows(for: message)
        XCTAssertEqual(rows.map(\.id.index), [0, 1, 3, 4, 5])
        guard case .tools(let calls) = rows[1].content else { return XCTFail("Expected adjacent tool group") }
        XCTAssertEqual(calls.map(\.id), ["a", "b"])
        guard case .block(.thinking("Summary")) = rows[2].content else { return XCTFail("Reasoning moved") }
    }

    func testResultIsJoinedByCallIDNotNameOrPosition() {
        let message = ChatMessage(role: .assistant, blocks: [
            .toolUse(call("a")), .toolUse(call("b")),
            .toolResult(.init(toolUseId: "b", content: "failed", isError: true)),
            .toolResult(.init(toolUseId: "a", content: "ok", isError: false))
        ])
        let rows = ToolTranscriptRow.rows(for: message)
        XCTAssertEqual(rows.count, 1)
        guard case .tools(let calls) = rows[0].content else { return XCTFail("Expected tools") }
        XCTAssertEqual(calls.map(\.result), ["ok", "failed"])
        XCTAssertEqual(calls.map(\.isError), [false, true])
    }

    func testOrphanResultRemainsReadable() {
        let message = ChatMessage(role: .assistant, blocks: [
            .toolResult(.init(toolUseId: "orphan", content: "receipt", isError: false))
        ])
        guard case .tools(let calls) = ToolTranscriptRow.rows(for: message).first?.content else {
            return XCTFail("Orphan result was hidden")
        }
        XCTAssertEqual(calls.first?.id, "orphan")
        XCTAssertEqual(calls.first?.result, "receipt")
    }

    func testGroupIdentityDoesNotChangeWhenAnotherCallArrives() {
        var message = ChatMessage(id: "turn", role: .assistant, blocks: [.toolUse(call("a"))])
        let before = ToolTranscriptRow.rows(for: message).first?.id
        message.blocks.append(.toolUse(call("b")))
        XCTAssertEqual(ToolTranscriptRow.rows(for: message).first?.id, before)
    }

    func testBoundedUnicodeOutputPreservesOriginalReceipt() {
        let text = String(repeating: "\u{1F600}", count: 40_000)
        XCTAssertEqual(ToolPresentation.preview(text).count, ToolPresentation.outputPageSize)
        XCTAssertEqual(ToolPresentation.preview(text, limit: Int.max).count, ToolPresentation.maximumPreviewSize)
        XCTAssertEqual(ToolPresentation.preview(text, limit: -1), "")
        XCTAssertEqual(text.count, 40_000)
    }

    func testPartialAndOversizedInputAreNotParsedAsCommands() {
        var tool = call()
        XCTAssertEqual(ToolPresentation(tool: tool, live: true).summary, "pwd")
        tool.input = "{\"command\":"
        XCTAssertEqual(ToolPresentation(tool: tool, live: true).summary, "")
        tool.input = "{\"command\":\"" + String(repeating: "x", count: 70_000) + "\"}"
        XCTAssertNil(ToolPresentation(tool: tool, live: true).inputObject)
    }

    func testImagePreviewWaitsForCompletion() {
        var tool = call()
        tool.input = "{\"file_path\":\"assets/image.png\"}"
        XCTAssertNil(ToolPresentation(tool: tool, live: true).imagePath)
        tool.result = ""
        XCTAssertEqual(ToolPresentation(tool: tool, live: false).imagePath, "assets/image.png")
    }
}
