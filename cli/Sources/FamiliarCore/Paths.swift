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
    public var afterMeetingMinutes: [Int]?

    public static func load(_ paths: Paths) -> Config? {
        (try? Data(contentsOf: paths.config)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
    }
}
