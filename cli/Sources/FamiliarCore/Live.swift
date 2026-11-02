import Foundation

/// マスコットが読む現在の状態。familiar だけが書き、マスコットは読むだけ。
public struct Live: Codable, Equatable {
    public var scanning = false
    public var scanStarted: Date?
    public var pending = 0
    /// スヌーズ中など、いま判断を求めてはいないが片付いていない提案
    public var held = 0
    /// 判断待ちの先頭の提案の題。吹き出しで件数の代わりに伝える
    public var headline: String?
    /// 見回りが終わるたびに増える。マスコットは変化で終了を知る
    public var scanSeq = 0
    public var lastAdded = 0
    public var lastError: String?

    public init() {}

    static func load(_ url: URL) -> Live {
        guard let data = try? Data(contentsOf: url) else { return Live() }
        return (try? Store.decoder.decode(Live.self, from: data)) ?? Live()
    }

    func save(to url: URL) throws {
        try Store.encoder.encode(self).write(to: url, options: .atomic)
    }
}
