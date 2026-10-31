import Foundation

public typealias Event = [String: Any]

public enum ToolPolicy {
    /// 接続先と無関係なサーバー。拒否リストとは別に、サーバー単位で外す。
    static let unrelatedServers = [
        "mcp__blender", "mcp__pencil", "mcp__playwright",
        "mcp__openaiDeveloperDocs", "mcp__plugin_context7_context7",
    ]
    static let builtinDenied = ["Bash", "Write", "Edit", "WebFetch"]
    /// CLI が自前で足すツール。MCP ツールの読み込みと構造化出力に要る。
    public static let harness: Set<String> = ["ToolSearch", "StructuredOutput"]

    public static func list(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// 読み取り専用の前提が崩れていれば理由を返す。実行中のイベントごとに呼ぶ。
    public static func violation(in event: Event, allowed: Set<String>) -> String? {
        let permitted = allowed.union(harness)
        if event["type"] as? String == "system", event["subtype"] as? String == "init",
           let tools = event["tools"] as? [String] {
            let extra = tools.filter { !permitted.contains($0) }.sorted()
            if !extra.isEmpty { return "許可リストにないツールが見えています: \(extra.joined(separator: ", "))" }
        }
        for call in toolCalls(in: event) where !permitted.contains(call.name) {
            return "許可リストにないツールを呼びました: \(call.name)"
        }
        return nil
    }

    public static func toolCalls(in event: Event) -> [(name: String, input: [String: Any])] {
        guard event["type"] as? String == "assistant",
              let message = event["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }
        return content.compactMap { block in
            guard block["type"] as? String == "tool_use", let name = block["name"] as? String else { return nil }
            return (name, block["input"] as? [String: Any] ?? [:])
        }
    }
}

public struct RunOutcome {
    public var exitCode: Int32
    public var result: Event?
    public var violation: String?
}

public struct ClaudeRunner {
    var binary: String
    var timeout: TimeInterval

    public init(env: [String: String] = ProcessInfo.processInfo.environment, timeout: TimeInterval = 600) {
        // launchd の PATH には ~/.local/bin がない
        binary = env["CLAUDE_BIN"] ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/claude").path
        self.timeout = timeout
    }

    /// 権限まわりの共通の引数。ユーザー設定の defaultMode: auto を dontAsk で上書きし、hook を止める。
    static func baseArguments(model: String, schema: String, maxTurns: Int, budget: String,
                              allowed: [String], denied: [String]) -> [String] {
        [
            "--model", model, "--max-turns", String(maxTurns), "--max-budget-usd", budget,
            "--output-format", "stream-json", "--verbose", "--no-session-persistence",
            "--json-schema", schema,
            "--permission-mode", "dontAsk", "--setting-sources", "user",
            "--settings", #"{"disableAllHooks":true}"#,
            "--tools", "ToolSearch",
            "--allowedTools", allowed.joined(separator: ","),
            "--disallowedTools", (denied + ToolPolicy.unrelatedServers + ToolPolicy.builtinDenied).joined(separator: ","),
        ]
    }

    /// `check` が理由を返したらプロセスを止める。
    public func run(prompt: String, arguments: [String], cwd: URL, check: (Event) -> String?) throws -> RunOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-p"] + arguments
        process.currentDirectoryURL = cwd
        // プロンプトは stdin で渡す。Process は引数を NFD に変換するので、日本語が分解されてしまう
        let input = Pipe()
        process.standardInput = input
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try input.fileHandleForWriting.close()

        let watchdog = DispatchWorkItem { [process] in if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        var outcome = RunOutcome(exitCode: 0)
        var buffer = Data()
        let handle = pipe.fileHandleForReading
        func consume(_ line: Data) {
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? Event else { return }
            if outcome.violation == nil, let reason = check(event) {
                outcome.violation = reason
                process.terminate()
            }
            if event["type"] as? String == "result" { outcome.result = event }
        }
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                consume(buffer.subdata(in: buffer.startIndex..<nl))
                buffer.removeSubrange(buffer.startIndex...nl)
            }
        }
        if !buffer.isEmpty { consume(buffer) }
        process.waitUntilExit()
        outcome.exitCode = process.terminationStatus
        return outcome
    }
}

extension RunOutcome {
    init(exitCode: Int32) { self.init(exitCode: exitCode, result: nil, violation: nil) }

    var cost: Double { result?["total_cost_usd"] as? Double ?? 0 }

    /// 成功した実行の structured_output を取り出す。
    func structured<T: Decodable>(_ type: T.Type) throws -> T {
        if let violation { throw FamiliarError.violation(violation) }
        guard exitCode == 0, let result, result["is_error"] as? Bool != true,
              let output = result["structured_output"] else {
            let detail = (result?["subtype"] as? String) ?? "結果なし"
            throw FamiliarError.failed("claude の実行に失敗しました（exit \(exitCode), \(detail)）")
        }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: output))
    }
}
