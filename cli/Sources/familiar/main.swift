import Foundation
import FamiliarCore

let usage = """
usage: familiar <command>
  scan [--model MODEL]                     見回りを 1 回行う（既定: haiku → sonnet の 2 段。指定時は 1 段）
  tick                                     launchd 用。予定に合えば見回る
  status                                   最後の見回りと当日の使用量
  list [--all] [--json]                    提案の一覧（既定: 判断待ちのみ）
  show <id>                                提案の詳細
  accept <id> [--note 指示] [--approve] [--force]
                                           計画を立て、承認されたら OUTPUT.md に従って実行する
  say --text 言葉 [--about 提案か実行]        キャラクターと話す
  say --start                              初回の声をかけてもらう
  thread [--limit 件数]                     会話の履歴と変更案を JSON で表示する
  apply | discard                          指示ファイルの変更案を反映する / 取り消す
  workspace                                記憶と指示の置き場を用意して表示する
  dream [--force]                          最近の判断を長期記憶へ整理する
  runs [--limit 件数] [--json]               実行の記録の一覧
  log <id> [--json]                        実行の記録を読みやすくして表示する
  dismiss <id> [理由]
  snooze <id> [時間数]                      既定: 24
"""

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags = Set<String>()

    init(_ raw: [String], valued: Set<String>) throws {
        var it = raw.makeIterator()
        while let a = it.next() {
            if valued.contains(a) {
                guard let v = it.next() else { throw FamiliarError.invalidState("\(a) に値が必要です") }
                options[a] = v
            } else if a.hasPrefix("--") {
                flags.insert(a)
            } else {
                positional.append(a)
            }
        }
    }

    func id() throws -> String {
        guard let id = positional.first else { throw FamiliarError.invalidState(usage) }
        return id
    }
}

func printRow(_ s: Suggestion) {
    print("\(s.id)  [\(s.status.rawValue)] \(s.draft.urgency)  \(s.draft.title)")
}

func printReport(_ report: ScanReport) {
    for c in report.coverage where c.status != "ok" { print("! \(c.source) \(c.status): \(c.note)") }
    print("新しい提案 \(report.added.count) 件")
    report.added.forEach(printRow)
}

func printState(_ state: Conversation.State) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try encoder.encode(state), as: UTF8.self))
}

func run() throws {
    let argv = Array(CommandLine.arguments.dropFirst())
    guard let command = argv.first else { print(usage); return }
    let rest = Array(argv.dropFirst())
    let paths = Paths.standard()
    let store = Store(paths: paths)

    switch command {
    case "scan":
        let args = try Args(rest, valued: ["--model"])
        let scanner = Scanner(paths: paths)
        let model = args.options["--model"]
        guard let report = try scanner.scan(triage: model ?? "haiku", refine: model == nil ? "sonnet" : nil) else {
            print("別の見回りが実行中です")
            return
        }
        printReport(report)
    case "tick":
        if let (trigger, report) = try Scanner(paths: paths).tick(triage: "haiku", refine: "sonnet") {
            print("tick: \(trigger.rawValue)")
            printReport(report)
        }
        do {
            if let summary = try Dreamer(paths: paths).dream() { print("記憶を整理しました: \(summary)") }
        } catch {
            FileHandle.standardError.write(Data("dream: \(error)\n".utf8))
        }
    case "status":
        let state = ScheduleState.load(paths.schedule)
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        let show = { (d: Date?) in d.map(f.string(from:)) ?? "-" }
        print("最終試行: \(show(state.lastAttempt))\n最終成功: \(show(state.lastSuccess))")
        if let e = state.lastError { print("直近のエラー: \(e)") }
        print("今後の予定（他の参加者あり）: \(state.upcoming.count) 件")
        let open = try store.load().filter { $0.status == .new }.count
        print("判断待ちの提案: \(open) 件")
        let log = (try? String(contentsOf: paths.log, encoding: .utf8)) ?? ""
        let usage = Scanner.todayUsage(logText: log)
        print("今日の見回り: \(usage.runs) 回 / 換算 $\(String(format: "%.3f", usage.usd))")
    case "list":
        let args = try Args(rest, valued: [])
        let items = try store.load()
        let shown = args.flags.contains("--all") ? items : items.filter { $0.status == .new || $0.status == .accepting }
        if args.flags.contains("--json") {
            print(String(decoding: try Store.jsonLines(shown), as: UTF8.self))
            return
        }
        if shown.isEmpty { print("提案はありません") }
        shown.forEach(printRow)
    case "show":
        let id = try Args(rest, valued: []).id()
        guard let s = try store.load().first(where: { $0.id == id }) else { throw FamiliarError.notFound(id) }
        printRow(s)
        print("なぜ: \(s.draft.why)")
        for src in s.draft.sources { print("出典 [\(src.kind)] \(src.url)\n  \(src.excerpt)") }
        print("内容: \(s.draft.details)（期日: \(s.draft.due ?? "-")）")
        if let q = s.question { print("確認: \(q)") }
        if let url = s.resultUrl { print("結果: \(url)") }
    case "accept":
        let args = try Args(rest, valued: ["--note"])
        print(try Acceptor(paths: paths).accept(id: args.id(), note: args.options["--note"], force: args.flags.contains("--force"),
                                                approve: args.flags.contains("--approve")))
    case "workspace":
        let workspace = Workspace(paths: paths)
        try workspace.prepare()
        print(workspace.dir.path)
    case "runs":
        let args = try Args(rest, valued: ["--limit"])
        let items = Runs(paths: paths).list(limit: args.options["--limit"].flatMap(Int.init) ?? 50)
        if args.flags.contains("--json") {
            print(String(decoding: try JSONEncoder().encode(items), as: UTF8.self))
            return
        }
        for r in items { print("\(r.id)  [\(r.status)] \(r.label) \(r.model ?? "-")  \(r.costUsd.map { String(format: "$%.3f", $0) } ?? "-")") }
    case "log":
        let args = try Args(rest, valued: [])
        let entries = try Runs(paths: paths).entries(try args.id())
        if args.flags.contains("--json") {
            print(String(decoding: try JSONEncoder().encode(entries), as: UTF8.self))
            return
        }
        print(Runs.render(entries))
    case "say":
        let args = try Args(rest, valued: ["--text", "--about"])
        let words = args.options["--text"]
        guard words != nil || args.flags.contains("--start") else { throw FamiliarError.invalidState(usage) }
        try printState(Conversation(paths: paths).say(words, about: args.options["--about"]))
    case "thread":
        let args = try Args(rest, valued: ["--limit"])
        try printState(Conversation(paths: paths).state(limit: args.options["--limit"].flatMap(Int.init) ?? 200))
    case "apply": try printState(Conversation(paths: paths).apply())
    case "discard": try printState(Conversation(paths: paths).discard())
    case "dream":
        let args = try Args(rest, valued: [])
        print(try Dreamer(paths: paths).dream(force: args.flags.contains("--force")) ?? "整理することはありません")
    case "dismiss":
        let args = try Args(rest, valued: [])
        let reason = args.positional.dropFirst().joined(separator: " ")
        var decided: Suggestion?
        try store.transition(try args.id()) { s in
            guard s.status.isOpen else { throw FamiliarError.invalidState("\(s.id) は \(s.status.rawValue) です") }
            s.status = .dismissed
            s.dismissReason = reason.isEmpty ? nil : reason
            decided = s
        }
        if let decided { try Workspace(paths: paths).record("却下", decided, detail: reason) }
    case "snooze":
        let args = try Args(rest, valued: [])
        guard let hours = Double(args.positional.dropFirst().first ?? "24"), hours > 0 else {
            throw FamiliarError.invalidState("時間数が正しくありません")
        }
        var decided: Suggestion?
        try store.transition(try args.id()) { s in
            guard s.status.isOpen else { throw FamiliarError.invalidState("\(s.id) は \(s.status.rawValue) です") }
            s.status = .snoozed
            s.snoozedUntil = Date().addingTimeInterval(hours * 3600)
            decided = s
        }
        if let decided { try Workspace(paths: paths).record("後で", decided) }
    default:
        print(usage)
        exit(2)
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
