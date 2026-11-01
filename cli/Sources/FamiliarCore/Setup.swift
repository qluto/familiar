import Foundation

/// AI との対話で指示と記憶を整える。やり取りは setup.json に残し、閉じても続きから再開できる。
public struct Setup {
    public struct Line: Codable, Equatable { public var role: String; public var text: String }
    public struct Reply: Codable { public var message: String; public var done: Bool }

    struct Files: Decodable { var soul, user, heartbeat, output, memory: String? }
    struct Turn: Decodable { var message: String; var done: Bool; var files: Files }

    static let schema = #"""
    {"type":"object","additionalProperties":false,"required":["message","done","files"],
     "properties":{"message":{"type":"string"},"done":{"type":"boolean"},
      "files":{"type":"object","additionalProperties":false,"required":["soul","user","heartbeat","output","memory"],
       "properties":{"soul":{"type":["string","null"]},"user":{"type":["string","null"]},
        "heartbeat":{"type":["string","null"]},"output":{"type":["string","null"]},"memory":{"type":["string","null"]}}}}}
    """#

    let paths: Paths
    let workspace: Workspace
    let agent: AgentRun

    public init(paths: Paths, agent: AgentRun? = nil) {
        self.paths = paths
        self.workspace = Workspace(paths: paths)
        self.agent = agent ?? ClaudeAgent(runner: ClaudeRunner(), cwd: paths.state)
    }

    private var transcript: URL { paths.state.appendingPathComponent("setup.json") }

    public func log() -> [Line] {
        (try? Data(contentsOf: transcript)).flatMap { try? JSONDecoder().decode([Line].self, from: $0) } ?? []
    }

    /// 初回の対話がまだ終わっていない。BOOTSTRAP.md は対話を終えると消える。
    public func needed() throws -> Bool {
        try workspace.prepare()
        return FileManager.default.fileExists(atPath: workspace.file("BOOTSTRAP.md").path)
    }

    public func reset() throws {
        try? FileManager.default.removeItem(at: transcript)
    }

    func prompt(lines: [Line]) throws -> String {
        let rules = try String(contentsOf: paths.prompts.appendingPathComponent("BOOTSTRAP.md"), encoding: .utf8)
        let current = ["SOUL.md", "USER.md", "HEARTBEAT.md", "OUTPUT.md", "MEMORY.md"].map { name in
            let text = (try? String(contentsOf: workspace.file(name), encoding: .utf8)) ?? "なし"
            return "### \(name)\n\(text)"
        }.joined(separator: "\n\n")
        let dialog = lines.map { "\($0.role): \($0.text)" }.joined(separator: "\n")
        return "\(rules)\n\n## 今のファイル\n\(current)\n\n## ここまでの対話\n\(dialog.isEmpty ? "まだありません。最初の言葉をかけてください" : dialog)\n"
    }

    /// `text` が nil なら対話を始める。実行に失敗したら何も残さず、同じ言葉で再送できる。
    public func say(_ text: String?) throws -> Reply {
        try workspace.prepare()
        var lines = log()
        if let text { lines.append(Line(role: "ユーザー", text: text)) }
        let turn = try agent.run(prompt: try prompt(lines: lines), schema: Self.schema).structured(Turn.self)
        if turn.done { try apply(turn.files) }
        lines.append(Line(role: "familiar", text: turn.message))
        if turn.done {
            try reset()
        } else {
            try JSONEncoder().encode(lines).write(to: transcript, options: .atomic)
        }
        return Reply(message: turn.message, done: turn.done)
    }

    private func apply(_ files: Files) throws {
        guard (files.user?.count ?? 0) <= Workspace.userLimit, (files.memory?.count ?? 0) <= Workspace.memoryLimit else {
            throw FamiliarError.failed("内容が上限を超えたので保存しませんでした。短くするよう伝えてください")
        }
        let changed = [("SOUL.md", files.soul), ("USER.md", files.user), ("HEARTBEAT.md", files.heartbeat),
                       ("OUTPUT.md", files.output), ("MEMORY.md", files.memory)]
        for case let (name, text?) in changed {
            // 書き換える前の版を 1 つ残し、人が戻せるようにする
            if let old = try? String(contentsOf: workspace.file(name), encoding: .utf8) {
                try old.write(to: workspace.file("memory/previous-\(name)"), atomically: true, encoding: .utf8)
            }
            try text.write(to: workspace.file(name), atomically: true, encoding: .utf8)
        }
        try? FileManager.default.removeItem(at: workspace.file("BOOTSTRAP.md"))
    }
}
