import Foundation

public enum FamiliarError: Error, CustomStringConvertible {
    case notFound(String)
    case invalidState(String)
    case failed(String)

    public var description: String {
        switch self {
        case .notFound(let id): return "提案 \(id) が見つかりません"
        case .invalidState(let m), .failed(let m): return m
        }
    }
}

/// suggestions.jsonl の読み書き。CLI・マスコット・iPhone 経由の操作が重なるので flock で直列化する。
public struct Store {
    let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func jsonLines(_ items: [Suggestion]) throws -> Data {
        try encoder.encode(items)
    }

    public func load(now: Date = Date()) throws -> [Suggestion] {
        try locked { Self.wake(try read(), now: now) }
    }

    @discardableResult
    public func update<T>(now: Date = Date(), _ body: (inout [Suggestion]) throws -> T) throws -> T {
        try locked {
            var items = Self.wake(try read(), now: now)
            let result = try body(&items)
            try write(items)
            var live = Live.load(paths.live)
            live.pending = items.filter { $0.status == .new }.count
            live.headline = items.first { $0.status == .new }?.draft.title
            live.held = items.filter { $0.status == .snoozed || $0.status == .accepting }.count
            try live.save(to: paths.live)
            return result
        }
    }

    /// live.json の見回り状態を更新する。pending は update が書く。
    func updateLive(_ body: (inout Live) -> Void) throws {
        try locked {
            var live = Live.load(paths.live)
            body(&live)
            try live.save(to: paths.live)
        }
    }

    /// 重複を除いて追加し、追加した提案を返す。却下・採用済みと重なるものも再度は出さない。
    public func merge(_ drafts: [Draft], now: Date = Date()) throws -> [Suggestion] {
        try update(now: now) { items in
            var known = Self.taken(items)
            var added: [Suggestion] = []
            for draft in drafts {
                let s = Suggestion(draft: draft, now: now)
                guard !s.dedupeKeys.isEmpty, known.isDisjoint(with: s.dedupeKeys) else { continue }
                known.formUnion(s.dedupeKeys)
                added.append(s)
            }
            items += added
            return added
        }
    }

    /// 出した提案の出典と、渡した先の URL。渡した仕事の issue や PR を、別の提案として出し直さないため。
    static func taken(_ items: [Suggestion]) -> Set<String> {
        Set(items.flatMap(\.dedupeKeys) + items.compactMap { $0.resultUrl.map(Dedupe.normalize) })
    }

    /// すでに出した提案と出典が重ならない候補だけを返す。
    public func unseen(_ drafts: [Draft], now: Date = Date()) throws -> [Draft] {
        let known = Self.taken(try load(now: now))
        return drafts.filter { known.isDisjoint(with: Dedupe.keys(for: $0.sources)) }
    }

    public func transition(_ id: String, now: Date = Date(), _ body: (inout Suggestion) throws -> Void) throws {
        try update(now: now) { items in
            guard let i = items.firstIndex(where: { $0.id == id }) else { throw FamiliarError.notFound(id) }
            try body(&items[i])
            items[i].updatedAt = now
        }
    }

    static func wake(_ items: [Suggestion], now: Date) -> [Suggestion] {
        items.map { item in
            guard item.status == .snoozed, let until = item.snoozedUntil, until <= now else { return item }
            var woken = item
            woken.status = .new
            woken.snoozedUntil = nil
            return woken
        }
    }

    private func read() throws -> [Suggestion] {
        guard FileManager.default.fileExists(atPath: paths.suggestions.path) else { return [] }
        let text = try String(contentsOf: paths.suggestions, encoding: .utf8)
        return try text.split(separator: "\n").map {
            try Self.decoder.decode(Suggestion.self, from: Data($0.utf8))
        }
    }

    private func write(_ items: [Suggestion]) throws {
        let lines = try items.map { String(decoding: try Self.encoder.encode($0), as: UTF8.self) }
        let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try Data(body.utf8).write(to: paths.suggestions, options: .atomic)
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: paths.state, withIntermediateDirectories: true)
        let fd = open(paths.lock.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw FamiliarError.failed("ロックを開けません: \(paths.lock.path)") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw FamiliarError.failed("ロックを取得できません") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
