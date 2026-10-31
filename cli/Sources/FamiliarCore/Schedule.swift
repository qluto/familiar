import Foundation

public struct Schedule {
    public enum Trigger: String { case interval, meeting }

    public var intervalMinutes = 30
    public var startHour = 9
    public var endHour = 20
    public var weekdays: Set<Int> = [2, 3, 4, 5, 6]  // Calendar の表記で月〜金
    public var meetingLeadMinutes = 30

    public init(config: Config? = nil) {
        intervalMinutes = config?.intervalMinutes ?? intervalMinutes
        startHour = config?.startHour ?? startHour
        endHour = config?.endHour ?? endHour
        weekdays = config?.weekdays.map(Set.init) ?? weekdays
        meetingLeadMinutes = config?.meetingLeadMinutes ?? meetingLeadMinutes
    }

    func isWorkingTime(_ now: Date, calendar: Calendar) -> Bool {
        let c = calendar.dateComponents([.weekday, .hour], from: now)
        guard let day = c.weekday, let hour = c.hour else { return false }
        return weekdays.contains(day) && hour >= startHour && hour < endHour
    }

    /// 会議前のきっかけを優先する。作業時間外でも、人と会う予定の前には見回る。
    public func decide(now: Date, state: ScheduleState, calendar: Calendar = .current) -> Trigger? {
        let lead = TimeInterval(meetingLeadMinutes * 60)
        if meeting(now: now, state: state, lead: lead) != nil { return .meeting }
        guard isWorkingTime(now, calendar: calendar) else { return nil }
        guard let last = state.lastAttempt else { return .interval }
        // launchd の起動は数秒ずれるので、1 tick 分遅れないよう少し余裕を見る
        return now.timeIntervalSince(last) >= TimeInterval(intervalMinutes * 60) - 30 ? .interval : nil
    }

    public func meeting(now: Date, state: ScheduleState) -> Date? {
        meeting(now: now, state: state, lead: TimeInterval(meetingLeadMinutes * 60))
    }

    private func meeting(now: Date, state: ScheduleState, lead: TimeInterval) -> Date? {
        state.upcoming.first { start in
            let wait = start.timeIntervalSince(now)
            return wait > 0 && wait <= lead && !state.triggered.contains(start)
        }
    }
}

public struct ScheduleState: Codable, Equatable {
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var lastError: String?
    public var upcoming: [Date] = []
    public var triggered: [Date] = []

    public init() {}

    public static func load(_ url: URL) -> ScheduleState {
        guard let data = try? Data(contentsOf: url) else { return ScheduleState() }
        return (try? Store.decoder.decode(ScheduleState.self, from: data)) ?? ScheduleState()
    }

    public func save(to url: URL) throws {
        try Store.encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// 見回りの多重起動を防ぐ。取れなければ nil を返す（誰かが実行中）。
final class ScanLock {
    private let fd: Int32

    init?(url: URL) {
        fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
    }

    deinit { close(fd) }  // close で flock も外れる
}
