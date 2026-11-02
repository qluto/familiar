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
    public var details: String
    public var due: String?
    public var confidence: Double
}

extension Draft {
    private enum LegacyKeys: CodingKey { case linear_draft }
    private struct Legacy: Decodable { var description: String; var due: String? }

    /// 以前の提案は Linear 用の linear_draft に本文と期日を持っていた。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Legacy.self, forKey: .linear_draft)
        self.init(title: try c.decode(String.self, forKey: .title), why: try c.decode(String.self, forKey: .why),
                  sources: try c.decode([Source].self, forKey: .sources), urgency: try c.decode(String.self, forKey: .urgency),
                  effort: try c.decode(String.self, forKey: .effort), kind: try c.decode(String.self, forKey: .kind),
                  details: try c.decodeIfPresent(String.self, forKey: .details) ?? legacy?.description ?? "",
                  due: try c.decodeIfPresent(String.self, forKey: .due) ?? legacy?.due,
                  confidence: try c.decode(Double.self, forKey: .confidence))
    }
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
    public var resultUrl: String?
    /// エージェントが返事を待っている質問。
    public var question: String?
    /// エージェントが承認を待っている計画。
    public var plan: String?
    /// 人が計画を承認した。質問への返事のあとも、計画に戻らず続ける。
    public var approved: Bool?
    /// 指示と質問のやり取り。採用をやり直すときに渡す。
    public var dialog: [String]?

    private enum CodingKeys: String, CodingKey {
        case id, dedupeKeys, draft, status, createdAt, updatedAt, snoozedUntil, dismissReason, question, plan, approved, dialog
        case resultUrl = "linearUrl" // 保存済みの提案と同じキーのまま読む
    }

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
