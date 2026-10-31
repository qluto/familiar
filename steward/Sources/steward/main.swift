import Foundation
import StewardCore

let usage = """
usage: steward <command>
  scan [--model MODEL]                     見回りを 1 回行う（既定: sonnet）
  list [--all]                             提案の一覧（既定: 判断待ちのみ）
  show <id>                                提案の詳細
  accept <id> [--title T] [--team T] [--due YYYY-MM-DD] [--force]
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
                guard let v = it.next() else { throw StewardError.invalidState("\(a) に値が必要です") }
                options[a] = v
            } else if a.hasPrefix("--") {
                flags.insert(a)
            } else {
                positional.append(a)
            }
        }
    }

    func id() throws -> String {
        guard let id = positional.first else { throw StewardError.invalidState(usage) }
        return id
    }
}

func printRow(_ s: Suggestion) {
    print("\(s.id)  [\(s.status.rawValue)] \(s.draft.urgency)  \(s.draft.title)")
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
        let report = try Scanner(paths: paths).scan(model: args.options["--model"] ?? "sonnet")
        for c in report.coverage where c.status != "ok" { print("! \(c.source) \(c.status): \(c.note)") }
        print("新しい提案 \(report.added.count) 件")
        report.added.forEach(printRow)
    case "list":
        let args = try Args(rest, valued: [])
        let items = try store.load()
        let shown = args.flags.contains("--all") ? items : items.filter { $0.status == .new || $0.status == .accepting }
        if shown.isEmpty { print("提案はありません") }
        shown.forEach(printRow)
    case "show":
        let id = try Args(rest, valued: []).id()
        guard let s = try store.load().first(where: { $0.id == id }) else { throw StewardError.notFound(id) }
        printRow(s)
        print("なぜ: \(s.draft.why)")
        for src in s.draft.sources { print("出典 [\(src.kind)] \(src.url)\n  \(src.excerpt)") }
        let d = s.draft.linear_draft
        print("Linear 下書き: \(d.title)（team: \(d.team ?? "-"), due: \(d.due ?? "-")）\n\(d.description)")
        if let url = s.linearUrl { print("Linear: \(url)") }
    case "accept":
        let args = try Args(rest, valued: ["--title", "--team", "--due"])
        let edits = AcceptEdits(title: args.options["--title"], team: args.options["--team"], due: args.options["--due"])
        print(try Acceptor(paths: paths).accept(id: args.id(), edits: edits, force: args.flags.contains("--force")))
    case "dismiss":
        let args = try Args(rest, valued: [])
        let reason = args.positional.dropFirst().joined(separator: " ")
        try store.transition(try args.id()) { s in
            guard s.status.isOpen else { throw StewardError.invalidState("\(s.id) は \(s.status.rawValue) です") }
            s.status = .dismissed
            s.dismissReason = reason.isEmpty ? nil : reason
        }
    case "snooze":
        let args = try Args(rest, valued: [])
        guard let hours = Double(args.positional.dropFirst().first ?? "24"), hours > 0 else {
            throw StewardError.invalidState("時間数が正しくありません")
        }
        try store.transition(try args.id()) { s in
            guard s.status.isOpen else { throw StewardError.invalidState("\(s.id) は \(s.status.rawValue) です") }
            s.status = .snoozed
            s.snoozedUntil = Date().addingTimeInterval(hours * 3600)
        }
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
