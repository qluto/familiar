import Foundation

/// 実行中のイベントを 1 行ずつ残す。記録できなくても実行は止めない。
final class RunRecord {
    private let handle: FileHandle

    init?(dir: URL, label: String, model: String?, prompt: String, now: Date = Date()) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        Runs.prune(dir, now: now)
        let url = dir.appendingPathComponent("\(Runs.stamp(now))-\(UUID().uuidString.prefix(4).lowercased()).jsonl")
        // メールなどの本文を含むので、本人だけが読める形で作る
        guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = handle
        let head: [String: Any] = ["type": "familiar_run", "label": label, "model": model ?? NSNull(),
                                   "started": ISO8601DateFormatter().string(from: now), "prompt": prompt]
        if let line = try? JSONSerialization.data(withJSONObject: head) { append(line) }
    }

    func append(_ line: Data) {
        try? handle.write(contentsOf: line + Data([0x0A]))
    }

    deinit { try? handle.close() }
}

public struct RunSummary: Codable {
    public var id: String
    public var label: String
    public var model: String?
    public var started: String
    /// running / done / failed / stopped（結果が出ないまま止まった）
    public var status: String
    public var costUsd: Double?
}

public struct RunEntry: Codable, Equatable {
    /// prompt / text / tool / output / error / final
    public var kind: String
    public var title: String
    public var text: String
}

public struct Runs {
    static let keepDays = 14.0
    /// `ClaudeRunner` の上限より長く結果がなければ、止まったとみなす
    static let stalled: TimeInterval = 660
    static let entryLimit = 6000

    let dir: URL

    public init(paths: Paths) { dir = paths.state.appendingPathComponent("runs") }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    static func prune(_ dir: URL, now: Date) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names {
            let url = dir.appendingPathComponent(name)
            let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if let date, now.timeIntervalSince(date) > keepDays * 86400 { try? fm.removeItem(at: url) }
        }
    }

    func url(_ id: String) throws -> URL {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw FamiliarError.notFound(id)
        }
        let url = dir.appendingPathComponent("\(id).jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { throw FamiliarError.notFound(id) }
        return url
    }

    private func events(_ url: URL) -> [Event] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? Event
        }
    }

    /// 新しい順。記録について話す対話そのものは、一覧を埋めないよう出さない。
    public func list(limit: Int = 50, now: Date = Date()) -> [RunSummary] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".jsonl") }.sorted(by: >)
        var found: [RunSummary] = []
        for name in names where found.count < limit {
            let url = dir.appendingPathComponent(name)
            let all = events(url)
            guard let head = all.first, head["type"] as? String == "familiar_run",
                  let label = head["label"] as? String, label != "review" else { continue }
            let result = all.last { $0["type"] as? String == "result" }
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            let status: String
            if let result {
                status = result["is_error"] as? Bool == true ? "failed" : "done"
            } else {
                status = now.timeIntervalSince(modified ?? now) < Self.stalled ? "running" : "stopped"
            }
            found.append(RunSummary(id: String(name.dropLast(6)), label: label, model: head["model"] as? String,
                                    started: head["started"] as? String ?? "", status: status,
                                    costUsd: result?["total_cost_usd"] as? Double))
        }
        return found
    }

    public func entries(_ id: String) throws -> [RunEntry] {
        Self.entries(from: events(try url(id)))
    }

    static func clip(_ text: String) -> String {
        guard text.count > entryLimit else { return text }
        return String(text.prefix(entryLimit)) + "\n…（\(text.count - entryLimit) 字を省略）"
    }

    static func pretty(_ value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String { return text }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    /// tool_result の content は文字列か、text ブロックの配列。
    static func resultText(_ content: Any?) -> String {
        if let blocks = content as? [Event] {
            return blocks.map { $0["text"] as? String ?? pretty($0) }.joined(separator: "\n")
        }
        return pretty(content)
    }

    static func entries(from events: [Event]) -> [RunEntry] {
        var out: [RunEntry] = []
        var tools: [String: String] = [:]
        for event in events {
            let blocks = (event["message"] as? Event)?["content"] as? [Event] ?? []
            switch event["type"] as? String {
            case "familiar_run":
                out.append(RunEntry(kind: "prompt", title: "指示", text: clip(event["prompt"] as? String ?? "")))
            case "assistant":
                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        out.append(RunEntry(kind: "text", title: "発言", text: clip(block["text"] as? String ?? "")))
                    case "thinking":
                        if let text = block["thinking"] as? String, !text.isEmpty {
                            out.append(RunEntry(kind: "text", title: "思考", text: clip(text)))
                        }
                    case "tool_use":
                        let name = block["name"] as? String ?? "tool"
                        if let id = block["id"] as? String { tools[id] = name }
                        out.append(RunEntry(kind: "tool", title: name, text: clip(pretty(block["input"]))))
                    default: break
                    }
                }
            case "user":
                for block in blocks where block["type"] as? String == "tool_result" {
                    let name = (block["tool_use_id"] as? String).flatMap { tools[$0] } ?? "tool"
                    let failed = block["is_error"] as? Bool == true
                    out.append(RunEntry(kind: failed ? "error" : "output", title: "\(name) の結果",
                                        text: clip(resultText(block["content"]))))
                }
            case "result":
                let failed = event["is_error"] as? Bool == true
                let body = event["structured_output"] ?? event["result"] ?? event["subtype"]
                out.append(RunEntry(kind: failed ? "error" : "final", title: "結果", text: clip(pretty(body))))
            default: break
            }
        }
        return out
    }

    public static func render(_ entries: [RunEntry]) -> String {
        entries.map { "### \($0.title)\n\($0.text)" }.joined(separator: "\n\n")
    }
}
