import CryptoKit
import Foundation

public enum Status: String, Codable, CaseIterable {
    case new, accepting, accepted, snoozed, dismissed

    /// まだ人の判断を待っている状態。
    public var isOpen: Bool { self == .new || self == .snoozed }
}

public struct Source: Codable, Equatable {
    public var kind: String
    public var url: String
    public var excerpt: String
}

public struct LinearDraft: Codable, Equatable {
    public var team: String?
    public var title: String
    public var description: String
    public var due: String?
}

public struct Coverage: Codable, Equatable {
    public var source: String
    public var status: String
    public var note: String
}

/// 見回りのモデルが返す提案。`--json-schema` の形と一致させる。
public struct Draft: Codable, Equatable {
    public var title: String
    public var why: String
    public var sources: [Source]
    public var urgency: String
    public var effort: String
    public var kind: String
    public var linear_draft: LinearDraft
    public var confidence: Double
}

public struct ScanOutput: Codable, Equatable {
    public var coverage: [Coverage]
    public var upcoming_events: [String]
    public var suggestions: [Draft]

    /// 読めない時刻は捨てる。予定の取得に失敗しても見回り自体は成立させる。
    public var upcomingDates: [Date] {
        let f = ISO8601DateFormatter()
        return upcoming_events.compactMap { f.date(from: $0) }.sorted()
    }
}

public struct Suggestion: Codable, Equatable {
    public var id: String
    public var dedupeKeys: [String]
    public var draft: Draft
    public var status: Status
    public var createdAt: Date
    public var updatedAt: Date
    public var snoozedUntil: Date?
    public var dismissReason: String?
    public var linearUrl: String?

    public init(draft: Draft, now: Date) {
        let keys = Dedupe.keys(for: draft.sources)
        self.id = Self.makeID(keys: keys)
        self.dedupeKeys = keys
        self.draft = draft
        self.status = .new
        self.createdAt = now
        self.updatedAt = now
    }

    static func makeID(keys: [String]) -> String {
        let digest = SHA256.hash(data: Data(keys.joined(separator: "\n").utf8))
        return digest.prefix(3).map { String(format: "%02x", $0) }.joined()
    }
}
