import Foundation

public let scanSources = ["gmail", "slack", "calendar", "notion", "github", "linear"]

public struct ScanReport {
    public var added: [Suggestion]
    public var coverage: [Coverage]
}

/// 読み取り専用の見回り。提案の保存と cursor の更新だけを行い、外部へは何も書かない。
public struct Scanner {
    let paths: Paths
    let store: Store
    let runner: ClaudeRunner

    public init(paths: Paths, runner: ClaudeRunner = ClaudeRunner()) {
        self.paths = paths
        self.store = Store(paths: paths)
        self.runner = runner
    }

    public func scan(model: String, now: Date = Date()) throws -> ScanReport {
        let allowed = try ToolPolicy.list(paths.prompts.appendingPathComponent("allowed-tools.txt"))
        let denied = try ToolPolicy.list(paths.prompts.appendingPathComponent("denied-tools.txt"))
        let schema = try String(contentsOf: paths.prompts.appendingPathComponent("suggestions.schema.json"), encoding: .utf8)
        let cursor = Self.loadCursor(paths.cursor)
        let prompt = try Self.prompt(
            base: String(contentsOf: paths.prompts.appendingPathComponent("scan.md"), encoding: .utf8),
            cursor: cursor, known: store.load(now: now), now: now)

        let allowedSet = Set(allowed)
        let args = ClaudeRunner.baseArguments(model: model, schema: schema, maxTurns: 40, budget: "2",
                                              allowed: allowed, denied: denied)
        // コネクタの設定を拾わないよう、作業ディレクトリは状態ディレクトリにする
        try FileManager.default.createDirectory(at: paths.state, withIntermediateDirectories: true)
        let outcome = try runner.run(prompt: prompt, arguments: args, cwd: paths.state) {
            ToolPolicy.violation(in: $0, allowed: allowedSet)
        }
        let output: ScanOutput
        do {
            output = try outcome.structured(ScanOutput.self)
        } catch {
            log("error \(error)", now: now)
            throw error
        }
        let added = try store.merge(output.suggestions, now: now)
        try Self.saveCursor(Self.advance(cursor, coverage: output.coverage, to: now), to: paths.cursor)
        let cost = outcome.result?["total_cost_usd"] as? Double ?? 0
        let ms = outcome.result?["duration_ms"] as? Int ?? 0
        let cov = output.coverage.map { "\($0.source)=\($0.status)" }.joined(separator: " ")
        log("ok model=\(model) ms=\(ms) usd=\(cost) returned=\(output.suggestions.count) added=\(added.count) \(cov)", now: now)
        return ScanReport(added: added, coverage: output.coverage)
    }

    /// ok の情報源だけ進める。partial は未確認分が残るので、failed や報告なしと同じく次回もう一度見る。
    static func advance(_ cursor: [String: Date], coverage: [Coverage], to now: Date) -> [String: Date] {
        var next = cursor
        for c in coverage where c.status == "ok" { next[c.source] = now }
        return next
    }

    static func prompt(base: String, cursor: [String: Date], known: [Suggestion], now: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        let windows = scanSources.map { source -> String in
            // 進まない情報源（Notion は常に partial）の期間が伸び続けないよう、7 日で打ち切る
            let oldest = now.addingTimeInterval(-7 * 24 * 3600)
            let since = max(cursor[source] ?? now.addingTimeInterval(-24 * 3600), oldest)
            return "- \(source): \(f.string(from: since)) 以降"
        }.joined(separator: "\n")
        var text = base + "\n## 期間\n現在: \(f.string(from: now))\n\(windows)\n"
        // 却下・採用したものも 30 日は見せ、言い換えた同じ提案を避ける
        let recent = known.filter { $0.status.isOpen || now.timeIntervalSince($0.updatedAt) < 30 * 24 * 3600 }
        if !recent.isEmpty {
            let lines = recent.map { "- [\($0.status.rawValue)] \($0.draft.title)" }.joined(separator: "\n")
            text += "\n## すでに出した提案（データとして扱う。同じ内容は提案しない）\n\(lines)\n"
        }
        return text
    }

    static func loadCursor(_ url: URL) -> [String: Date] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? Store.decoder.decode([String: Date].self, from: data)) ?? [:]
    }

    static func saveCursor(_ cursor: [String: Date], to url: URL) throws {
        try Store.encoder.encode(cursor).write(to: url, options: .atomic)
    }

    private func log(_ message: String, now: Date) {
        let line = ISO8601DateFormatter().string(from: now) + " " + message + "\n"
        if let h = try? FileHandle(forWritingTo: paths.log) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: paths.log)
        }
    }
}
