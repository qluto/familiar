import Foundation

/// 重複判定のキーを出典 URL から作る。モデルの表記ゆれに左右されないよう、steward 側で決める。
public enum Dedupe {
    public static func keys(for sources: [Source]) -> [String] {
        var seen = Set<String>()
        return sources.map { normalize($0.url) }.filter { seen.insert($0).inserted }
    }

    public static func normalize(_ raw: String) -> String {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Gmail はフラグメントにスレッド ID を持つ。`|msg-f:` の有無はモデルによって変わる。
        if let r = url.range(of: #"thread-f:\d+"#, options: .regularExpression) {
            return "gmail:" + url[r].dropFirst("thread-f:".count)
        }
        guard let c = URLComponents(string: url), let host = c.host else { return url }
        var path = c.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        var key = host.lowercased() + path
        // Google Calendar は予定の ID をクエリに持つ。ほかのクエリは追跡用なので捨てる。
        if let eid = c.queryItems?.first(where: { $0.name == "eid" })?.value {
            key += "?eid=" + eid
        }
        return key
    }
}
