import Foundation
import FamiliarCore

let usage = """
usage: familiar <command>
  scan [--model MODEL]                     見回りを 1 回行う（既定: haiku → sonnet の 2 段。指定時は 1 段）
  tick                                     launchd 用。予定に合えば見回る
  status                                   最後の見回りと当日の使用量
  schedule                                 見回りの予定を JSON で表示する（config.json の値と既定値）
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
  eval [--model MODEL] [--only 名前] [--dir 場所]
                                           見回りの判断を架空の情報源で確かめる（既定: haiku、evals/scan）
  handled <id> [メモ]                       自分で済ませた
  dismiss <id> [理由]
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
    encoder.outputFormatting = .sortedKeys // 読むたびに順番が変わると、画面が変更ありと判断する
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
    case "schedule":
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(Schedule(config: Config.load(paths))), as: UTF8.self))
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
    case "eval":
        let args = try Args(rest, valued: ["--model", "--only", "--dir"])
        let dir = args.options["--dir"].map { URL(fileURLWithPath: $0) }
            ?? paths.prompts.deletingLastPathComponent().appendingPathComponent("evals/scan")
        let cases = try EvalCase.load(dir).filter { c in args.options["--only"].map { c.name.contains($0) } ?? true }
        let evaluator = Evaluator(prompts: paths.prompts, model: args.options["--model"] ?? "haiku")
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("familiar-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        var results = [Evaluator.Result?](repeating: nil, count: cases.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: cases.count) { i in
            let r: Evaluator.Result
            do { r = try evaluator.run(cases[i], cwd: cwd) }
            catch { r = Evaluator.Result(name: cases[i].name, problems: ["実行に失敗しました: \(error)"], cost: 0) }
            lock.lock(); results[i] = r; lock.unlock()
        }
        var cost = 0.0
        for r in results.compactMap({ $0 }) {
            cost += r.cost
            print("\(r.problems.isEmpty ? "ok  " : "NG  ") \(r.name)")
            r.problems.forEach { print("      \($0)") }
        }
        let passed = results.filter { $0?.problems.isEmpty == true }.count
        print("\(passed)/\(cases.count) 合格  usd=\(String(format: "%.3f", cost))  記録: \(cwd.path)/runs")
        if passed < cases.count { exit(1) }
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
    case "handled":
        let args = try Args(rest, valued: [])
        let note = args.positional.dropFirst().joined(separator: " ")
        var decided: Suggestion?
        try store.transition(try args.id()) { s in
            guard s.status.isOpen else { throw FamiliarError.invalidState("\(s.id) は \(s.status.rawValue) です") }
            s.status = .handled
            s.snoozedUntil = nil
            decided = s
        }
        if let decided { try Workspace(paths: paths).record("自分で済ませた", decided, detail: note) }
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
