import Foundation

public struct Paths {
    public let state: URL
    public let prompts: URL

    public init(state: URL, prompts: URL) {
        self.state = state
        self.prompts = prompts
    }

    public static func standard(env: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
        let state = env["FAMILIAR_STATE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/familiar")
        let prompts = env["FAMILIAR_ROOT"].map { URL(fileURLWithPath: $0).appendingPathComponent("prompts") }
            ?? bundledPrompts(executable: Bundle.main.executableURL)
            // 開発時: cli/Sources/FamiliarCore/Paths.swift から repo の直下へ戻る
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("prompts")
        return Paths(state: state, prompts: prompts)
    }

    /// アプリ同梱のとき、実行ファイルは Contents/MacOS、プロンプトは Contents/Resources にある。
    static func bundledPrompts(executable: URL?) -> URL? {
        guard let contents = executable?.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent(),
              contents.lastPathComponent == "Contents" else { return nil }
        let prompts = contents.appendingPathComponent("Resources/prompts")
        return FileManager.default.fileExists(atPath: prompts.path) ? prompts : nil
    }

    public var suggestions: URL { state.appendingPathComponent("suggestions.jsonl") }
    public var cursor: URL { state.appendingPathComponent("cursor.json") }
    public var log: URL { state.appendingPathComponent("scan.log") }
    public var config: URL { state.appendingPathComponent("config.json") }
    public var live: URL { state.appendingPathComponent("live.json") }
    public var schedule: URL { state.appendingPathComponent("schedule.json") }
    public var instructions: [URL] { ["sources.md", "output.md"].map(state.appendingPathComponent) }

    /// ユーザーが書き換える指示を読む。なければ同梱の既定を置く。
    public func instruction(_ name: String) throws -> String {
        let url = state.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            var text = try String(contentsOf: prompts.appendingPathComponent(name), encoding: .utf8)
            if name == "output.md", let team = Config.load(self)?.linearTeam { text += "- Linear のチームは \(team)\n" }
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    var lock: URL { state.appendingPathComponent("state.lock") }
    var scanLock: URL { state.appendingPathComponent("scan.lock") }
}

public struct Config: Codable {
    public var linearTeam: String?
    public var intervalMinutes: Int?
    public var startHour: Int?
    public var endHour: Int?
    public var weekdays: [Int]?
    public var meetingLeadMinutes: Int?

    public static func load(_ paths: Paths) -> Config? {
        (try? Data(contentsOf: paths.config)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
    }
}
