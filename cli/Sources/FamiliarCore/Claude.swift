import Foundation

public typealias Event = [String: Any]

public struct RunOutcome {
    public var exitCode: Int32
    public var result: Event?
    /// 実行の記録の ID
    public var run: String? = nil
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

    /// 権限はエージェントとユーザーの設定に任せる。hook は無人の実行で動かさない。
    static func baseArguments(model: String, schema: String, maxTurns: Int, budget: String) -> [String] {
        [
            "--model", model, "--max-turns", String(maxTurns), "--max-budget-usd", budget,
            "--output-format", "stream-json", "--verbose", "--no-session-persistence",
            "--json-schema", schema,
            "--setting-sources", "user",
            "--settings", #"{"disableAllHooks":true}"#,
        ]
    }

    /// 流れてくるイベントは cwd の runs/ にそのまま残し、あとから見返せるようにする。
    public func run(prompt: String, arguments: [String], cwd: URL, label: String = "run") throws -> RunOutcome {
        let model = arguments.firstIndex(of: "--model").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let record = RunRecord(dir: cwd.appendingPathComponent("runs"), label: label, model: model, prompt: prompt)
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
        outcome.run = record?.id
        var buffer = Data()
        let handle = pipe.fileHandleForReading
        func consume(_ line: Data) {
            record?.append(line)
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? Event else { return }
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
    init(exitCode: Int32) { self.init(exitCode: exitCode, result: nil) }

    var cost: Double { result?["total_cost_usd"] as? Double ?? 0 }

    /// 成功した実行の structured_output を取り出す。
    func structured<T: Decodable>(_ type: T.Type) throws -> T {
        guard exitCode == 0, let result, result["is_error"] as? Bool != true,
              let output = result["structured_output"] else {
            // モデルが応答を止めたときなどは subtype が success のままなので、本文の 1 行目を伝える
            let reason = (result?["result"] as? String)?.split(separator: "\n").first.map(String.init)
            let detail = reason ?? (result?["subtype"] as? String) ?? "結果なし"
            throw FamiliarError.failed("claude の実行に失敗しました（exit \(exitCode), \(detail)）")
        }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: output))
    }
}
