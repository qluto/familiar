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

@Test func instructionsSeedOnceAndKeepUserEdits() throws {
    let dir = tempPaths().state
    let paths = Paths(state: dir.appendingPathComponent("state"), prompts: dir)
    try FileManager.default.createDirectory(at: paths.state, withIntermediateDirectories: true)
    try "既定\n".write(to: paths.prompts.appendingPathComponent("output.md"), atomically: true, encoding: .utf8)
    try #"{"linearTeam":"Qluto"}"#.write(to: paths.config, atomically: true, encoding: .utf8)
    #expect(try paths.instruction("output.md").contains("Qluto"))
    try "自分の指示".write(to: paths.prompts.appendingPathComponent("output.md"), atomically: true, encoding: .utf8)
    try "書き換えた".write(to: paths.state.appendingPathComponent("output.md"), atomically: true, encoding: .utf8)
    #expect(try paths.instruction("output.md") == "書き換えた")
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
    try FileManager.default.createDirectory(at: paths.state, withIntermediateDirectories: true)
    try "Linear に作る".write(to: paths.state.appendingPathComponent("output.md"), atomically: true, encoding: .utf8)
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
