@testable import vphone_cli
import Foundation
import Testing

struct SessionTests {
    @Test func duplicateIDsNeverAcceptAnotherGoal() {
        var session = JevSessionRequests()
        guard case let .goal(first) = session.accept(#"{"id":"one","goal":"Inspect first item"}"#) else {
            Issue.record("Expected first request"); return
        }
        #expect(first.goal == "Inspect first item")
        guard case let .rejected(id, reason) = session.accept(#"{"id":"one","goal":"Mutate another item"}"#) else {
            Issue.record("Duplicate request was accepted"); return
        }
        #expect(id == "one")
        #expect(reason.contains("Duplicate"))
        guard case let .goal(second) = session.accept(#"{"id":"two","goal":"Inspect second item"}"#) else {
            Issue.record("Expected independent request"); return
        }
        #expect(second.id == "two")
    }

    @Test(arguments: ["", "[]", "not json", #"{"id":"one","goal":""}"#,
        #"{"id":"","goal":"Inspect"}"#, #"{"id":1,"goal":"Inspect"}"#,
        #"{"id":"one","goal":"Inspect","extra":true}"#])
    func invalidRequestsAreRejected(line: String) {
        var session = JevSessionRequests()
        guard case .rejected = session.accept(line) else { Issue.record("Invalid request accepted"); return }
        guard case .goal = session.accept(#"{"id":"valid","goal":"Inspect"}"#) else {
            Issue.record("Invalid input prevented later request"); return
        }
    }

    @Test func decompositionFindsHelperFromExecutableOutsideWorkingDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scripts = root.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let helper = scripts.appendingPathComponent("jev_codex_planner.py")
        try Data("#!/usr/bin/env python3\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let resolved = try VPhoneJevCommand.bundledPlannerPath(executable: root.appendingPathComponent(".build/arm64-apple-macosx/debug/vphone-cli"))
        #expect(resolved == helper.path)
        try FileManager.default.removeItem(at: helper)
        #expect(throws: (any Error).self) {
            try VPhoneJevCommand.bundledPlannerPath(executable: root.appendingPathComponent(".build/arm64-apple-macosx/debug/vphone-cli"))
        }
    }

    @MainActor @Test func resultCarriesOnlyItsOwnGoalEvidence() throws {
        let event = JevSessionEvent(id: "second", goal: "Inspect second item", outcome: .exhausted(steps: 1),
            elapsedSeconds: 0.25, inputTokens: 10, completionAudit: nil)
        let value = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        #expect(value["event"] as? String == "result")
        #expect(value["id"] as? String == "second")
        #expect(value["goal"] as? String == "Inspect second item")
        #expect(value["outcome"] as? String == "exhausted")
        #expect(value["completionAudit"] == nil)
    }
}
