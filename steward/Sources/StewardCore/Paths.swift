import Foundation

public struct Paths {
    public let state: URL
    public let prompts: URL

    public init(state: URL, prompts: URL) {
        self.state = state
        self.prompts = prompts
    }

    public static func standard(env: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
        let state = env["DESK_STEWARD_STATE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/desk-steward")
        // steward/Sources/StewardCore/Paths.swift から repo の直下へ戻る
        let root = env["DESK_STEWARD_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
        return Paths(state: state, prompts: root.appendingPathComponent("prompts"))
    }

    public var suggestions: URL { state.appendingPathComponent("suggestions.jsonl") }
    public var cursor: URL { state.appendingPathComponent("cursor.json") }
    public var log: URL { state.appendingPathComponent("scan.log") }
    public var config: URL { state.appendingPathComponent("config.json") }
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

    public static func load(_ paths: Paths) -> Config? {
        (try? Data(contentsOf: paths.config)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
    }
}
