import Foundation

/// Calendar days. A day is a `Date` at local midnight; days are stored as
/// `yyyy-MM-dd` text so they mean the same day on every device, whatever
/// its time zone. Weekdays use the Dart numbering the data is stored with:
/// 1 = Monday … 7 = Sunday.
public enum Days {
    /// Made once: creating a calendar is slow, and dates are worked out
    /// thousands of times per screen. Follows the device's time zone.
    public static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .autoupdatingCurrent
        return c
    }()

    public static let monday = 1
    public static let sunday = 7

    /// Midnight at the start of `date`'s day.
    public static func start(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    /// Whole calendar days later (or earlier), safe across daylight saving.
    public static func add(_ date: Date, _ days: Int) -> Date {
        calendar.date(byAdding: .day, value: days, to: start(date)) ?? date
    }

    /// Whole calendar days from `a` to `b`.
    public static func between(_ a: Date, _ b: Date) -> Int {
        let c = calendar
        return c.dateComponents([.day], from: start(a), to: start(b)).day ?? 0
    }

    public static func key(_ date: Date) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return pad(p.year ?? 0, 4) + "-" + pad(p.month ?? 0, 2) + "-" + pad(p.day ?? 0, 2)
    }

    private static func pad(_ n: Int, _ width: Int) -> String {
        let s = String(n)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    public static func parse(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// 1 = Monday … 7 = Sunday.
    public static func weekday(_ date: Date) -> Int {
        let apple = calendar.component(.weekday, from: date)  // 1 = Sunday
        return (apple + 5) % 7 + 1
    }

    /// The first day of `date`'s week, for weeks starting on `firstDay`.
    public static func startOfWeek(_ date: Date, firstDay: Int = sunday) -> Date {
        let back = ((weekday(date) - firstDay) % 7 + 7) % 7
        return add(start(date), -back)
    }

    /// The same day of the month `months` later, clamped to shorter months.
    public static func addMonths(_ date: Date, _ months: Int) -> Date {
        let c = calendar
        let p = c.dateComponents([.year, .month, .day], from: date)
        guard let first = c.date(from: DateComponents(
            year: p.year, month: (p.month ?? 1) + months, day: 1)) else { return date }
        let length = c.range(of: .day, in: .month, for: first)?.count ?? 28
        return c.date(byAdding: .day, value: min(p.day ?? 1, length) - 1, to: first) ?? first
    }

    /// Weekday numbers in display order for weeks starting on `first`.
    public static func order(startingOn first: Int) -> [Int] {
        (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }
}

/// `HH:mm` times of day.
public struct TimeOfDay: Hashable, Sendable {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public init?(_ text: String) {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        self.init(hour: parts[0], minute: parts[1])
    }

    public var text: String { String(format: "%02d:%02d", hour, minute) }

    /// Today at this time, for pickers and labels.
    public func date(on day: Date = Date()) -> Date {
        Days.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    public init(_ date: Date) {
        let p = Days.calendar.dateComponents([.hour, .minute], from: date)
        self.init(hour: p.hour ?? 0, minute: p.minute ?? 0)
    }
}

/// Timestamps in the form the Dart apps write and read
/// (`2026-11-15T07:48:12.123Z`). Dart can write up to six decimal places,
/// which Apple's ISO 8601 parser doesn't accept, so this parses by hand.
public enum Timestamp {
    public static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    public static func parse(_ text: String) -> Date? {
        var base = text
        var fraction = 0.0
        var zone = ""
        if text.hasSuffix("Z") {
            zone = "Z"
            base = String(text.dropLast())
        } else if let r = text.range(of: #"[+-]\d\d:?\d\d$"#, options: .regularExpression),
            text.distance(from: text.startIndex, to: r.lowerBound) > 10
        {
            zone = String(text[r])
            base = String(text[..<r.lowerBound])
        }
        if let dot = base.firstIndex(of: ".") {
            fraction = Double("0" + base[dot...]) ?? 0
            base = String(base[..<dot])
        }
        let f = ISO8601DateFormatter()
        if zone.isEmpty {
            // No zone means local time, as in Dart.
            f.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            f.timeZone = .current
        } else {
            f.formatOptions = [.withInternetDateTime]
            base += zone
        }
        return f.date(from: base).map { $0.addingTimeInterval(fraction) }
    }
}
