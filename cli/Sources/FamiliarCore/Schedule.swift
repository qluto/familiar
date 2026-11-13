import Foundation

public struct Schedule: Encodable {
    public enum Trigger: String { case interval, time, meeting, afterMeeting = "after_meeting" }
    public enum Mode: String, Encodable { case interval, times }

    public var mode = Mode.interval
    /// 1 日の中の時刻（0 時からの分）。mode が times のとき、この時刻を過ぎたら 1 回見回る
    public var times = [8 * 60]
    public var meetingScans = true
    public var intervalMinutes = 30
    public var startHour = 9
    public var endHour = 20
    public var weekdays: Set<Int> = [2, 3, 4, 5, 6]  // Calendar の表記で月〜金
    public var meetingLeadMinutes = 30
    /// 会議の終了から何分後に見回るか。書き起こしやメモは終了の数分〜数十分後に届く
    public var afterMeetingMinutes = [10, 25]
    /// 終了後の見回りを逃したとき（スリープなど）、どこまで遅れても見回るか
    static let afterMeetingGrace: TimeInterval = 15 * 60

    public init(config: Config? = nil) {
        intervalMinutes = config?.intervalMinutes ?? intervalMinutes
        startHour = config?.startHour ?? startHour
        endHour = config?.endHour ?? endHour
        weekdays = config?.weekdays.map(Set.init) ?? weekdays
        meetingLeadMinutes = config?.meetingLeadMinutes ?? meetingLeadMinutes
        afterMeetingMinutes = config?.afterMeetingMinutes ?? afterMeetingMinutes
        mode = config?.scanMode.flatMap(Mode.init(rawValue:)) ?? mode
        let parsed = (config?.times ?? []).compactMap(Self.minutes)
        if !parsed.isEmpty { times = Array(Set(parsed)).sorted() }
        meetingScans = config?.meetingScans ?? meetingScans
    }

    /// "8:00" や "08:00" を 0 時からの分にする。読めなければ nil
    static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    enum CodingKeys: String, CodingKey { case mode, times, meetingScans, intervalMinutes, startHour, endHour, weekdays }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(times.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) }, forKey: .times)
        try c.encode(meetingScans, forKey: .meetingScans)
        try c.encode(intervalMinutes, forKey: .intervalMinutes)
        try c.encode(startHour, forKey: .startHour)
        try c.encode(endHour, forKey: .endHour)
        try c.encode(weekdays.sorted(), forKey: .weekdays)
    }

    func isWorkingTime(_ now: Date, calendar: Calendar) -> Bool {
        let c = calendar.dateComponents([.weekday, .hour], from: now)
        guard let day = c.weekday, let hour = c.hour else { return false }
        return weekdays.contains(day) && hour >= startHour && hour < endHour
    }

    /// 会議の前後のきっかけを優先する。作業時間外でも、人と会う予定の前後には見回る。
    public func decide(now: Date, state: ScheduleState, calendar: Calendar = .current) -> Trigger? {
        if meetingScans {
            if meeting(now: now, state: state) != nil { return .meeting }
            if afterMeeting(now: now, state: state) { return .afterMeeting }
        }
        if mode == .times { return timeIsDue(now: now, state: state, calendar: calendar) ? .time : nil }
        guard isWorkingTime(now, calendar: calendar) else { return nil }
        guard let last = state.lastAttempt else { return .interval }
        // launchd の起動は数秒ずれるので、1 tick 分遅れないよう少し余裕を見る
        return now.timeIntervalSince(last) >= TimeInterval(intervalMinutes * 60) - 30 ? .interval : nil
    }

    /// 今日の時刻のうち、過ぎた中で最も新しいものの後にまだ見回っていない。
    /// スリープで時刻を逃しても、戻ったときに 1 回だけ見回る。いくつ逃しても 1 回にまとめる
    func timeIsDue(now: Date, state: ScheduleState, calendar: Calendar) -> Bool {
        guard let day = calendar.dateComponents([.weekday], from: now).weekday, weekdays.contains(day) else { return false }
        let midnight = calendar.startOfDay(for: now)
        let passed = times.compactMap { calendar.date(byAdding: .minute, value: $0, to: midnight) }.filter { $0 <= now }
        guard let latest = passed.max() else { return false }
        return (state.lastAttempt ?? .distantPast) < latest
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

    /// 終了後の見回りの時刻を過ぎ、それ以降まだ見回っていない。
    /// 見回ると lastAttempt が進むので、同じ時刻で二度は動かない。ほかのきっかけで見回った後も省く
    func afterMeeting(now: Date, state: ScheduleState) -> Bool {
        state.ends.contains { end in
            afterMeetingMinutes.contains { minutes in
                let due = end.addingTimeInterval(TimeInterval(minutes * 60))
                let late = now.timeIntervalSince(due)
                return late >= 0 && late < Self.afterMeetingGrace && (state.lastAttempt ?? .distantPast) < due
            }
        }
    }

    /// 見回りが返すのはまだ終わっていない予定だけ。終わった会議は終了後の見回りが済むまで残す
    public func keepEnds(previous: [Date], reported: [Date], now: Date) -> [Date] {
        let window = TimeInterval((afterMeetingMinutes.max() ?? 0) * 60) + Self.afterMeetingGrace
        let ended = previous.filter { $0 <= now && now.timeIntervalSince($0) <= window }
        return Set(ended + reported.filter { $0 > now }).sorted()
    }
}

public struct ScheduleState: Codable, Equatable {
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var lastError: String?
    /// 他の参加者がいる予定の開始時刻
    public var upcoming: [Date] = []
    /// 他の参加者がいる予定の終了時刻。終わったばかりのものも含む
    public var ends: [Date] = []
    public var triggered: [Date] = []

    public init() {}

    /// 以前の schedule.json には ends がない
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastAttempt = try c.decodeIfPresent(Date.self, forKey: .lastAttempt)
        lastSuccess = try c.decodeIfPresent(Date.self, forKey: .lastSuccess)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        upcoming = try c.decodeIfPresent([Date].self, forKey: .upcoming) ?? []
        ends = try c.decodeIfPresent([Date].self, forKey: .ends) ?? []
        triggered = try c.decodeIfPresent([Date].self, forKey: .triggered) ?? []
    }

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
