import Foundation
import Testing
@testable import StewardCore

func draft(_ title: String = "t", url: String = "https://example.com/a") -> Draft {
    Draft(title: title, why: "w", sources: [Source(kind: "gmail", url: url, excerpt: "e")],
          urgency: "high", effort: "small", kind: "other",
          linear_draft: LinearDraft(team: nil, title: title, description: "d", due: nil), confidence: 0.5)
}

func tempPaths() -> Paths {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return Paths(state: dir, prompts: dir)
}

@Test func gmailKeyIgnoresMessagePart() {
    let a = "https://mail.google.com/mail/?authuser=x@gmail.com#all/thread-f:1880332009637039257"
    #expect(Dedupe.normalize(a) == Dedupe.normalize(a + "|msg-f:1880332009637039257"))
}

@Test func urlKeyDropsTrackingButKeepsCalendarEvent() {
    #expect(Dedupe.normalize("https://GitHub.com/o/r/pull/1/?x=1#c") == "github.com/o/r/pull/1")
    #expect(Dedupe.normalize("https://calendar.google.com/calendar/event?eid=abc&u=1")
        != Dedupe.normalize("https://calendar.google.com/calendar/event?eid=def&u=1"))
}

@Test func mergeSkipsKnownEvenAfterDismiss() throws {
    let store = Store(paths: tempPaths())
    let added = try store.merge([draft(), draft("same source")])
    #expect(added.count == 1)
    try store.transition(added[0].id) { $0.status = .dismissed }
    #expect(try store.merge([draft("again")]).isEmpty)
    #expect(try store.load().count == 1)
}

@Test func snoozeWakesAfterDeadline() throws {
    let store = Store(paths: tempPaths())
    let now = Date()
    let s = try store.merge([draft()], now: now)[0]
    try store.transition(s.id, now: now) { $0.status = .snoozed; $0.snoozedUntil = now.addingTimeInterval(60) }
    #expect(try store.load(now: now)[0].status == .snoozed)
    #expect(try store.load(now: now.addingTimeInterval(61))[0].status == .new)
}

@Test func cursorAdvancesOnlyForReadSources() {
    let old = Date(timeIntervalSince1970: 0), now = Date()
    let next = Scanner.advance(["gmail": old, "slack": old], coverage: [
        Coverage(source: "gmail", status: "partial", note: ""),
        Coverage(source: "notion", status: "ok", note: ""),
        Coverage(source: "slack", status: "failed", note: ""),
    ], to: now)
    #expect(next["gmail"] == old && next["notion"] == now && next["slack"] == old)
    #expect(next["linear"] == nil)
}

@Test func promptClampsWindowToSevenDays() {
    let now = Date()
    let text = Scanner.prompt(base: "", cursor: ["gmail": Date(timeIntervalSince1970: 0)], known: [], now: now)
    #expect(!text.contains("1970"))
}

func assistant(_ name: String, _ input: [String: Any] = [:]) -> Event {
    ["type": "assistant", "message": ["content": [["type": "tool_use", "name": name, "input": input]]]]
}

@Test func policyStopsToolsOutsideAllowlist() {
    let allowed: Set<String> = ["mcp__x__read"]
    #expect(ToolPolicy.violation(in: assistant("mcp__x__read"), allowed: allowed) == nil)
    #expect(ToolPolicy.violation(in: assistant("ToolSearch"), allowed: allowed) == nil)
    #expect(ToolPolicy.violation(in: assistant("mcp__x__send"), allowed: allowed) != nil)
    let initEvent: Event = ["type": "system", "subtype": "init", "tools": ["ToolSearch", "mcp__x__send"]]
    #expect(ToolPolicy.violation(in: initEvent, allowed: allowed) != nil)
}

@Test func writeGuardRejectsUpdateChangedValueAndSecondCall() {
    let tool = Acceptor.writeTool
    let expected: [String: Any] = ["team": "Q", "title": "T", "priority": 2]
    var calls = 0
    #expect(Acceptor.writeViolation(in: assistant(tool, expected), expected: expected, calls: &calls) == nil)
    #expect(Acceptor.writeViolation(in: assistant(tool, expected), expected: expected, calls: &calls) != nil)
    calls = 0
    #expect(Acceptor.writeViolation(in: assistant(tool, expected.merging(["id": "QLU-5"]) { a, _ in a }),
                                    expected: expected, calls: &calls) != nil)
    calls = 0
    #expect(Acceptor.writeViolation(in: assistant(tool, ["team": "Q", "title": "X", "priority": 2]),
                                    expected: expected, calls: &calls) != nil)
    calls = 0
    #expect(Acceptor.writeViolation(in: assistant("mcp__claude_ai_Gmail__send_message"),
                                    expected: expected, calls: &calls) != nil)
}

@Test func writeGuardAcceptsSameValuesAfterJSONRoundTrip() throws {
    let s = Suggestion(draft: draft("日本語\nのタイトル"), now: Date())
    let expected = try Acceptor.issueInput(s, edits: AcceptEdits(due: "2026-11-07"), defaultTeam: "Qluto")
    let sent = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: expected)) as! [String: Any]
    var calls = 0
    #expect(Acceptor.writeViolation(in: assistant(Acceptor.writeTool, sent), expected: expected, calls: &calls) == nil)
}

@Test func issueInputNeedsTeamAndAppliesEdits() throws {
    var d = draft()
    d.linear_draft.due = "2026-11-01"
    let s = Suggestion(draft: d, now: Date())
    #expect(throws: StewardError.self) { try Acceptor.issueInput(s, edits: AcceptEdits(), defaultTeam: nil) }
    let input = try Acceptor.issueInput(s, edits: AcceptEdits(title: "直した", due: "2026-12-01"), defaultTeam: "Qluto")
    #expect(input["title"] as? String == "直した")
    #expect(input["dueDate"] as? String == "2026-12-01")
    #expect(input["priority"] as? Int == 2)
}
