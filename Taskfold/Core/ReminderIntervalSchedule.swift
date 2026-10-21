import Foundation

/// Elapsed-time reminder schedule, independent of a task's completion recurrence.
/// Nothing in this value registers notifications or changes a task.
struct ReminderIntervalSchedule: Equatable, Sendable {
    static let minuteRange = 5...10080
    static let maximumCount = 999
    static let maximumProjection = 60
    // Whole milliseconds in proleptic Gregorian years 1...9999, in UTC.
    private static let minimum: Int64 = -62_135_596_800_000
    private static let maximum: Int64 = 253_402_300_799_999
    private let anchorMilliseconds: Int64
    private let endMilliseconds: Int64?
    let intervalMinutes: Int
    let count: Int?
    var start: Date { Self.date(anchorMilliseconds) }
    var until: Date? { endMilliseconds.map(Self.date) }

    /// Dates are rounded once to milliseconds. No time-zone or wall-clock rule is implied.
    init?(start: Date, everyMinutes: Int, count: Int? = nil, until: Date? = nil) {
        guard Self.minuteRange.contains(everyMinutes),
              count == nil || (1...Self.maximumCount).contains(count!),
              let anchor = Self.milliseconds(start) else { return nil }
        let end = until.flatMap(Self.milliseconds)
        guard until == nil || end != nil, end == nil || end! >= anchor else { return nil }
        anchorMilliseconds = anchor; endMilliseconds = end
        intervalMinutes = everyMinutes; self.count = count
    }
    private static func milliseconds(_ date: Date) -> Int64? {
        let value = (date.timeIntervalSince1970 * 1000).rounded()
        guard value.isFinite, value >= Double(minimum), value <= Double(maximum) else { return nil }
        return Int64(value)
    }
    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
    /// Future occurrences only. Missed slots consume the count, never create a catch-up burst.
    /// Arithmetic seeks directly into old schedules; work is bounded by the projection cap.
    func dates(after now: Date, limit: Int = maximumProjection) -> [Date] {
        guard limit > 0, now.timeIntervalSince1970.isFinite else { return [] }
        let step = Int64(intervalMinutes) * 60_000
        let nowValue = now.timeIntervalSince1970 * 1000
        guard now < Self.date(Self.maximum) else { return [] }
        var ordinal: Int64 = 0
        if nowValue >= Double(anchorMilliseconds) {
            // This branch is bounded by the supported date domain before conversion.
            // Begin with the boundary slot and compare actual Date values below.
            // Multiplication near year 9999 can round a just-future millisecond up.
            ordinal = (Int64(nowValue.rounded(.down)) - anchorMilliseconds) / step
        }
        var result: [Date] = []
        let cap = min(limit, Self.maximumProjection)
        let last = min(endMilliseconds ?? Self.maximum, Self.maximum)
        while result.count < cap {
            if let count, ordinal >= Int64(count) { break }
            // Check the bound before multiplying; large caller dates cannot overflow.
            guard ordinal <= (last - anchorMilliseconds) / step else { break }
            let value = anchorMilliseconds + ordinal * step
            let date = Self.date(value)
            if date > now { result.append(date) }
            ordinal += 1
        }
        return result
    }
    /// Receipt validation proves an exact original slot, not merely a nearby timestamp.
    func contains(_ date: Date) -> Bool {
        guard let value = Self.milliseconds(date), Self.date(value) == date,
              value >= anchorMilliseconds, value <= (endMilliseconds ?? Self.maximum) else { return false }
        let step = Int64(intervalMinutes) * 60_000, delta = value - anchorMilliseconds
        guard delta % step == 0 else { return false }
        return count == nil || delta / step < Int64(count!)
    }
    /// Canonical identity excludes locale/display zone and includes every scheduling limit.
    var semanticFields: [String] {
        [String(anchorMilliseconds), String(intervalMinutes), count.map(String.init) ?? "", endMilliseconds.map(String.init) ?? ""]
    }
}
