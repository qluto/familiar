import Foundation

/// マスコットが読む現在の状態。familiar だけが書き、マスコットは読むだけ。
public struct Live: Codable, Equatable {
    public var scanning = false
    public var scanStarted: Date?
    public var pending = 0
    /// スヌーズ中など、いま判断を求めてはいないが片付いていない提案
    public var held = 0
    /// 判断待ちのうち、エージェントの質問か計画が人の返事を待っているもの
    public var asking = 0
    /// 判断待ちの先頭の提案の題。吹き出しで件数の代わりに伝える
    public var headline: String?
    /// 見回りが終わるたびに増える。マスコットは変化で終了を知る
    public var scanSeq = 0
    public var lastAdded = 0
    public var lastError: String?

    public init() {}

    /// 前の版が書いたファイルにない項目は既定値にする。読めずに見回りの状態を失わないため
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scanning = try c.decodeIfPresent(Bool.self, forKey: .scanning) ?? false
        scanStarted = try c.decodeIfPresent(Date.self, forKey: .scanStarted)
        pending = try c.decodeIfPresent(Int.self, forKey: .pending) ?? 0
        held = try c.decodeIfPresent(Int.self, forKey: .held) ?? 0
        asking = try c.decodeIfPresent(Int.self, forKey: .asking) ?? 0
        headline = try c.decodeIfPresent(String.self, forKey: .headline)
        scanSeq = try c.decodeIfPresent(Int.self, forKey: .scanSeq) ?? 0
        lastAdded = try c.decodeIfPresent(Int.self, forKey: .lastAdded) ?? 0
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }

    static func load(_ url: URL) -> Live {
        guard let data = try? Data(contentsOf: url) else { return Live() }
        return (try? Store.decoder.decode(Live.self, from: data)) ?? Live()
    }

    func save(to url: URL) throws {
        try Store.encoder.encode(self).write(to: url, options: .atomic)
    }
}
