import Foundation
import Testing
@testable import FamiliarCore

func draft(_ title: String = "t", url: String = "https://example.com/a") -> Draft {
    Draft(title: title, why: "w", sources: [Source(kind: "gmail", url: url, excerpt: "e")],
          urgency: "high", effort: "small", kind: "other",
          details: "d", due: nil, confidence: 0.5)
}

func tempPaths() -> Paths {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return Paths(state: dir, prompts: dir)
}

func tokyo() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return c
}

func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
    tokyo().date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

@Test func bundledPromptsAreFoundOnlyInsideAnApp() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let app = root.appendingPathComponent("a.app/Contents")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Resources/prompts"), withIntermediateDirectories: true)
    let found = Paths.bundledPrompts(executable: app.appendingPathComponent("MacOS/familiar"))
    #expect(found?.lastPathComponent == "prompts")
    #expect(Paths.bundledPrompts(executable: root.appendingPathComponent(".build/release/familiar")) == nil)
}

@Test func livePendingFollowsDecisions() throws {
    let paths = tempPaths(), store = Store(paths: paths)
    let s = try store.merge([draft()])[0]
    #expect(Live.load(paths.live).pending == 1)
    try store.transition(s.id) { $0.status = .snoozed; $0.snoozedUntil = Date().addingTimeInterval(60) }
    #expect(Live.load(paths.live).pending == 0)
    #expect(Live.load(paths.live).held == 1)
    try store.transition(s.id) { $0.status = .dismissed }
    #expect(Live.load(paths.live).held == 0)
}

@Test func tickRunsOnlyInWorkingHoursAtInterval() {
    let s = Schedule(), monday = at(2026, 11, 2, 10)
    var state = ScheduleState()
    #expect(s.decide(now: monday, state: state, calendar: tokyo()) == .interval)
    state.lastAttempt = monday.addingTimeInterval(-20 * 60)
    #expect(s.decide(now: monday, state: state, calendar: tokyo()) == nil)
    state.lastAttempt = monday.addingTimeInterval(-30 * 60 + 10)  // launchd のずれ
    #expect(s.decide(now: monday, state: state, calendar: tokyo()) == .interval)
    #expect(s.decide(now: at(2026, 11, 2, 20), state: ScheduleState(), calendar: tokyo()) == nil)
    #expect(s.decide(now: at(2026, 10, 31, 10), state: ScheduleState(), calendar: tokyo()) == nil)  // 土曜
}

@Test func meetingTriggersOnceEvenOutsideHours() {
    let s = Schedule(), saturday = at(2026, 10, 31, 21)
    var state = ScheduleState()
    state.lastAttempt = saturday
    state.upcoming = [saturday.addingTimeInterval(20 * 60)]
    #expect(s.decide(now: saturday, state: state, calendar: tokyo()) == .meeting)
    state.triggered = state.upcoming
    #expect(s.decide(now: saturday, state: state, calendar: tokyo()) == nil)
    state.triggered = []
    state.upcoming = [saturday.addingTimeInterval(40 * 60)]
    #expect(s.decide(now: saturday, state: state, calendar: tokyo()) == nil)
}

@Test func unseenDropsKnownSourcesOnly() throws {
    let store = Store(paths: tempPaths())
    try store.merge([draft()])
    let fresh = draft("new", url: "https://example.com/b")
    #expect(try store.unseen([draft("again"), fresh]) == [fresh])
}

@Test func upcomingSkipsUnreadableDates() {
    let out = ScanOutput(coverage: [], upcoming_events: ["2026-11-02T10:00:00+09:00", "明日"], suggestions: [])
    #expect(out.upcomingDates == [at(2026, 11, 2, 10)])
}

@Test func usageCountsOnlyTodaysSuccessfulRuns() {
    let now = at(2026, 11, 2, 12)
    let log = """
    2026-11-02T01:00:00Z ok model=haiku ms=1 usd=0.5 returned=0
    2026-11-02T01:30:00Z error boom
    2026-11-01T01:00:00Z ok model=haiku ms=1 usd=9
    """
    let usage = Scanner.todayUsage(logText: log, now: now, calendar: tokyo())
    #expect(usage.runs == 1 && usage.usd == 0.5)
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

@Test func promptListsSourcesFromTheCursorNotAFixedSet() {
    let text = Scanner.prompt(base: "", cursor: ["figma": Date()], known: [], now: Date())
    #expect(text.contains("- figma:") && text.contains("ここにない情報源") && !text.contains("gmail"))
}

@Test func oldDraftsKeepTheirTextAndDue() throws {
    let line = #"{"title":"t","why":"w","sources":[],"urgency":"low","effort":"small","kind":"other","confidence":0.5,"linear_draft":{"team":"Q","title":"t","description":"本文","due":"2026-11-07"}}"#
    let d = try JSONDecoder().decode(Draft.self, from: Data(line.utf8))
    #expect(d.details == "本文" && d.due == "2026-11-07")
}

func workspacePaths() throws -> Paths {
    let dir = tempPaths().state
    let paths = Paths(state: dir.appendingPathComponent("state"), prompts: dir)
    try FileManager.default.createDirectory(at: paths.state, withIntermediateDirectories: true)
    return paths
}

@Test func workspaceSeedsOnceAndKeepsUserEdits() throws {
    let paths = try workspacePaths()
    try "既定\n".write(to: paths.prompts.appendingPathComponent("OUTPUT.md"), atomically: true, encoding: .utf8)
    try #"{"linearTeam":"Qluto"}"#.write(to: paths.config, atomically: true, encoding: .utf8)
    let workspace = Workspace(paths: paths)
    #expect(try workspace.read("OUTPUT.md").contains("Qluto"))
    try "書き換えた".write(to: workspace.file("OUTPUT.md"), atomically: true, encoding: .utf8)
    #expect(try workspace.read("OUTPUT.md") == "書き換えた")
}

@Test func workspaceTakesOverEarlierInstructionFiles() throws {
    let paths = try workspacePaths()
    try "前の指示".write(to: paths.state.appendingPathComponent("output.md"), atomically: true, encoding: .utf8)
    #expect(try Workspace(paths: paths).read("OUTPUT.md") == "前の指示")
}

@Test func decisionsReachTheNextRunsContext() throws {
    let workspace = Workspace(paths: try workspacePaths())
    let s = Suggestion(draft: draft("請求書"), now: Date())
    try workspace.record("却下", s, detail: "経理が見るので\n不要")
    let context = workspace.context()
    #expect(context.contains("却下「請求書」") && context.contains("経理が見るので 不要"))
}

struct DreamFake: AgentRun {
    var output: [String: Any]
    func run(prompt: String, schema: String) throws -> RunOutcome {
        RunOutcome(exitCode: 0, result: ["structured_output": output])
    }
}

@Test func dreamWaitsForEnoughDecisionsAndRunsOncePerDay() throws {
    let paths = try workspacePaths()
    let workspace = Workspace(paths: paths)
    let dreamer = Dreamer(paths: paths, agent: DreamFake(output: ["user": "U", "memory": "M", "summary": "覚えた"]))
    try "".write(to: paths.prompts.appendingPathComponent("dream.md"), atomically: true, encoding: .utf8)
    try "前のU".write(to: paths.prompts.appendingPathComponent("USER.md"), atomically: true, encoding: .utf8)
    let s = Suggestion(draft: draft(), now: Date())
    let now = at(2026, 11, 2, 10)
    try workspace.record("却下", s, now: now.addingTimeInterval(-120))
    #expect(try dreamer.dream(now: now) == nil)
    try workspace.record("却下", s, now: now.addingTimeInterval(-120))
    try workspace.record("採用", s, now: now.addingTimeInterval(-120))
    #expect(try dreamer.dream(now: now) == "覚えた")
    #expect(try workspace.read("MEMORY.md") == "M" && workspace.read("USER.md") == "U")
    #expect(try workspace.read("memory/previous-USER.md") == "前のU")
    #expect(try workspace.read("DREAMS.md").contains("覚えた"))
    try workspace.record("却下", s, now: now.addingTimeInterval(60))
    try workspace.record("却下", s, now: now.addingTimeInterval(60))
    try workspace.record("却下", s, now: now.addingTimeInterval(60))
    #expect(try dreamer.dream(now: now.addingTimeInterval(3600)) == nil)
}

@Test func dreamKeepsMemoryWhenTheResultIsTooLong() throws {
    let paths = try workspacePaths()
    let workspace = Workspace(paths: paths)
    try "".write(to: paths.prompts.appendingPathComponent("dream.md"), atomically: true, encoding: .utf8)
    try "残す".write(to: paths.prompts.appendingPathComponent("USER.md"), atomically: true, encoding: .utf8)
    try workspace.record("却下", Suggestion(draft: draft(), now: Date()))
    let long = String(repeating: "あ", count: Workspace.userLimit + 1)
    let dreamer = Dreamer(paths: paths, agent: DreamFake(output: ["user": long, "memory": "", "summary": ""]))
    #expect(throws: FamiliarError.self) { try dreamer.dream(force: true) }
    #expect(try workspace.read("USER.md") == "残す")
}

struct SetupFake: AgentRun {
    var turn: [String: Any]
    func run(prompt: String, schema: String) throws -> RunOutcome {
        RunOutcome(exitCode: 0, result: ["structured_output": turn])
    }
}

func setupFixture(_ turn: [String: Any]) throws -> (Setup, Workspace) {
    let paths = try workspacePaths()
    try "ルール".write(to: paths.prompts.appendingPathComponent("BOOTSTRAP.md"), atomically: true, encoding: .utf8)
    try "前の魂".write(to: paths.prompts.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
    return (Setup(paths: paths, agent: SetupFake(turn: turn)), Workspace(paths: paths))
}

let noFiles: [String: Any] = ["soul": NSNull(), "user": NSNull(), "heartbeat": NSNull(), "output": NSNull(), "memory": NSNull()]

@Test func setupKeepsTheConversationUntilDone() throws {
    let (setup, workspace) = try setupFixture(["message": "お仕事は？", "done": false, "files": noFiles])
    #expect(try setup.needed())
    #expect(try setup.say(nil).done == false)
    _ = try setup.say("開発者です")
    #expect(setup.log().map(\.text) == ["お仕事は？", "開発者です", "お仕事は？"])
    #expect(try setup.prompt(lines: setup.log()).contains("開発者です"))
    #expect(try setup.needed())
    #expect(!FileManager.default.fileExists(atPath: workspace.file("USER.md").path))
}

@Test func setupWritesOnlyChangedFilesAndFinishes() throws {
    var files = noFiles
    files["user"] = "開発者"
    let (setup, workspace) = try setupFixture(["message": "保存します", "done": true, "files": files])
    try workspace.prepare()
    #expect(try setup.say("はい").done)
    #expect(try workspace.read("USER.md") == "開発者" && workspace.read("SOUL.md") == "前の魂")
    #expect(try !setup.needed() && setup.log().isEmpty)
}

@Test func setupRejectsAnOverlongFileAndKeepsTheConversation() throws {
    var files = noFiles
    files["user"] = String(repeating: "あ", count: Workspace.userLimit + 1)
    let (setup, workspace) = try setupFixture(["message": "保存します", "done": true, "files": files])
    #expect(throws: FamiliarError.self) { try setup.say("はい") }
    #expect(try !FileManager.default.fileExists(atPath: workspace.file("USER.md").path) && setup.needed())
}

@Test func existingWorkspacesAreNotAskedToOnboard() throws {
    let paths = try workspacePaths()
    try "前の指示".write(to: paths.state.appendingPathComponent("output.md"), atomically: true, encoding: .utf8)
    #expect(try !Setup(paths: paths).needed())
}

struct FakeAgent: AgentRun {
    var output: [String: Any]?
    func run(prompt: String, schema: String) throws -> RunOutcome {
        guard let output else { throw FamiliarError.failed("落ちた") }
        return RunOutcome(exitCode: 0, result: ["structured_output": output])
    }
}

func acceptFixture(_ agent: FakeAgent) throws -> (Acceptor, Store, String) {
    let paths = tempPaths()
    let store = Store(paths: paths)
    let added = try store.merge([draft()])
    let workspace = Workspace(paths: paths)
    try workspace.prepare()
    try "Linear に作る".write(to: workspace.file("OUTPUT.md"), atomically: true, encoding: .utf8)
    return (Acceptor(paths: paths, agent: agent), store, added[0].id)
}

@Test func doneStoresTheResult() throws {
    let (acceptor, store, id) = try acceptFixture(FakeAgent(output: ["status": "done", "message": "作った", "url": "https://x.test/1"]))
    #expect(try acceptor.accept(id: id, note: nil) == "https://x.test/1")
    let s = try store.load()[0]
    #expect(s.status == .accepted && s.resultUrl == "https://x.test/1")
}

@Test func questionWaitsForAReplyAndIsKeptForTheNextRun() throws {
    let (acceptor, store, id) = try acceptFixture(FakeAgent(output: ["status": "needs_input", "message": "どのチーム？", "url": NSNull()]))
    _ = try acceptor.accept(id: id, note: "急ぎで")
    let s = try store.load()[0]
    #expect(s.status == .new && s.question == "どのチーム？")
    #expect(s.dialog == ["あなた: 急ぎで", "エージェント: どのチーム？"])
    let prompt = try Acceptor.prompt(instructions: "x", suggestion: s)
    #expect(prompt.contains("急ぎで") && prompt.contains("どのチーム？") && prompt.contains("信頼できない"))
}

@Test func failureReturnsToTheHumanWithAWarning() throws {
    let (acceptor, store, id) = try acceptFixture(FakeAgent(output: nil))
    #expect(throws: FamiliarError.self) { try acceptor.accept(id: id, note: nil) }
    let s = try store.load()[0]
    #expect(s.status == .new && s.question?.contains("途中まで") == true)
}

// MARK: - 実行の記録と見直し

@discardableResult
func writeRun(_ paths: Paths, id: String = "20261102-090000-ab12", events: [Event]) throws -> String {
    let dir = paths.state.appendingPathComponent("runs")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let lines = try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
    try lines.joined(separator: "\n").write(to: dir.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
    return id
}

let head: Event = ["type": "familiar_run", "label": "scan", "model": "haiku", "started": "2026-11-02T00:00:00Z", "prompt": "見回って"]

@Test func recordKeepsThePromptAndEvents() throws {
    let dir = tempPaths().state.appendingPathComponent("runs")
    let record = try #require(RunRecord(dir: dir, label: "scan", model: "haiku", prompt: "見回って"))
    record.append(Data(#"{"type":"result","is_error":false,"total_cost_usd":0.5}"#.utf8))
    let paths = Paths(state: dir.deletingLastPathComponent(), prompts: dir)
    let run = try #require(Runs(paths: paths).list().first)
    #expect(run.label == "scan" && run.status == "done" && run.costUsd == 0.5)
    let name = try #require(FileManager.default.contentsOfDirectory(atPath: dir.path).first)
    let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
}

@Test func entriesFollowTheStreamAndSkipEmptyThinking() throws {
    let tool: Event = ["type": "assistant", "message": ["content": [
        ["type": "thinking", "thinking": ""],
        ["type": "text", "text": "Gmail を見ます"],
        ["type": "tool_use", "id": "1", "name": "search", "input": ["q": "x"]],
    ] as [Event]]]
    let result: Event = ["type": "user", "message": ["content": [
        ["type": "tool_result", "tool_use_id": "1", "content": [["type": "text", "text": "0 件"]] as [Event]],
    ] as [Event]]]
    let entries = Runs.entries(from: [head, tool, result, ["type": "result", "structured_output": ["n": 1]]])
    #expect(entries.map(\.kind) == ["prompt", "text", "tool", "output", "final"])
    #expect(entries[3].title == "search の結果" && entries[3].text == "0 件")
}

@Test func unfinishedRunIsRunningThenStopped() throws {
    let paths = tempPaths()
    try writeRun(paths, events: [head])
    #expect(Runs(paths: paths).list().first?.status == "running")
    #expect(Runs(paths: paths).list(now: Date().addingTimeInterval(3600)).first?.status == "stopped")
}

@Test func runIdCannotLeaveTheFolder() throws {
    let paths = tempPaths()
    try writeRun(paths, events: [head])
    #expect(throws: (any Error).self) { try Runs(paths: paths).entries("../config") }
}

@Test func oldRunsAndTheirReviewsArePruned() throws {
    let paths = tempPaths()
    try writeRun(paths, events: [head])
    let dir = paths.state.appendingPathComponent("runs")
    try Data().write(to: dir.appendingPathComponent("20261102-090000-ab12.review.json"))
    Runs.prune(dir, now: Date().addingTimeInterval(15 * 86400))
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
}

@Test func reviewListsNoReviewRuns() throws {
    let paths = tempPaths()
    var review = head
    review["label"] = "review"
    try writeRun(paths, events: [review])
    #expect(Runs(paths: paths).list().isEmpty)
}

func reviewFixture(files: [String: Any?]) throws -> (Review, Workspace, Paths, String) {
    let paths = tempPaths()
    try FileManager.default.createDirectory(at: paths.prompts, withIntermediateDirectories: true)
    for name in ["BOOTSTRAP.md", "SOUL.md", "USER.md", "HEARTBEAT.md", "OUTPUT.md", "review.md"] {
        try "".write(to: paths.prompts.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let id = try writeRun(paths, events: [head])
    let workspace = Workspace(paths: paths)
    try workspace.prepare()
    try "前".write(to: workspace.file("OUTPUT.md"), atomically: true, encoding: .utf8)
    var all: [String: Any] = ["soul": NSNull(), "user": NSNull(), "heartbeat": NSNull(), "output": NSNull(), "memory": NSNull()]
    for (k, v) in files { all[k] = v ?? NSNull() }
    let agent = FakeAgent(output: ["message": "こうします", "files": all])
    return (Review(paths: paths, agent: agent), workspace, paths, id)
}

@Test func reviewSavesOnlyWhenApplied() throws {
    let (review, workspace, _, id) = try reviewFixture(files: ["output": "後"])
    let state = try review.say(id, "直して")
    #expect(state.proposal == [Review.Change(file: "OUTPUT.md", before: "前", after: "後")])
    #expect(try String(contentsOf: workspace.file("OUTPUT.md"), encoding: .utf8) == "前")
    let applied = try review.apply(id)
    #expect(applied.proposal.isEmpty)
    #expect(try String(contentsOf: workspace.file("OUTPUT.md"), encoding: .utf8) == "後")
    #expect(try String(contentsOf: workspace.file("memory/previous-OUTPUT.md"), encoding: .utf8) == "前")
}

@Test func reviewRefusesAFileChangedAfterTheProposal() throws {
    let (review, workspace, _, id) = try reviewFixture(files: ["output": "後"])
    _ = try review.say(id, "直して")
    try "人が直した".write(to: workspace.file("OUTPUT.md"), atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { try review.apply(id) }
    #expect(try String(contentsOf: workspace.file("OUTPUT.md"), encoding: .utf8) == "人が直した")
}

@Test func reviewWithoutChangesKeepsNoProposal() throws {
    let (review, _, _, id) = try reviewFixture(files: ["output": "前"])
    #expect(try review.say(id, "どう思う？").proposal.isEmpty)
}
