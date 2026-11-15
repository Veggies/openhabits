import Foundation

/// Table names shared with the server and the Android app.
public enum Tables {
    public static let habits = "habits"
    public static let habitChecks = "habit_checks"
    public static let focusSessions = "focus_sessions"
    public static let scorecard = "scorecard"
    public static let reviews = "reviews"
    /// One row, `Prefs.rowId`: preferences that follow you to every device.
    public static let prefs = "prefs"
}

private func text(_ v: JSONValue?) -> String { v?.string ?? "" }
private func isDeleted(_ f: Fields) -> Bool { f[deletedField]?.bool == true }

public struct Prefs: Sendable {
    public static let rowId = "me"

    /// Nil until the person has answered the setup wizard's question.
    public let atomicHabits: Bool?
    /// `Days.sunday` or `Days.monday`.
    public let weekStart: Int
    /// How many pomodoros (focus sessions) to aim for each day.
    public let focusGoal: Int

    public init(_ f: Fields?) {
        atomicHabits = f?["atomicHabits"]?.bool
        weekStart = f?["weekStart"]?.int ?? Days.sunday
        focusGoal = f?["focusGoal"]?.int ?? 4
    }
}

public enum HabitKind: String, Sendable { case build, quit }

/// The optional Atomic Habits fields. Every one may be empty.
public struct HabitPlan: Sendable, Hashable {
    /// "I am a person who…": each check-in is a vote for this identity.
    public let identity: String
    /// When (`HH:mm`, or empty) and where.
    public let time: String
    public let location: String
    /// "After I [stackAfter], I will [habit]."
    public let stackAfter: String
    /// The version for now: starts tiny and can grow over time.
    public let twoMinute: String
    /// No longer shown; kept so older data still loads.
    public let goal: String
    /// When the size last changed or was checked in on (day key), or empty.
    public let steppedUpAt: String
    /// The person said the size feels right: no more suggestions.
    public let sizeSettled: Bool
    /// Every version the habit has had, oldest first. Empty until it first changes.
    public let sizeHistory: [Version]
    public let bundle: String
    public let reward: String
    /// For habits being broken: the four laws turned around, plus a contract.
    public let invisible: String
    public let unattractive: String
    public let difficult: String
    public let unsatisfying: String
    public let contract: String

    public struct Version: Sendable, Hashable {
        public let text: String
        public let since: String
    }

    public init(_ f: Fields) {
        identity = text(f["identity"])
        time = text(f["time"])
        location = text(f["location"])
        stackAfter = text(f["stackAfter"])
        twoMinute = text(f["twoMinute"])
        goal = text(f["goal"])
        steppedUpAt = text(f["steppedUpAt"])
        sizeSettled = f["sizeSettled"]?.bool == true
        sizeHistory = (f["sizeHistory"]?.array ?? []).compactMap { v in
            guard let o = v.object else { return nil }
            return Version(text: text(o["text"]), since: text(o["since"]))
        }
        bundle = text(f["bundle"])
        reward = text(f["reward"])
        invisible = text(f["invisible"])
        unattractive = text(f["unattractive"])
        difficult = text(f["difficult"])
        unsatisfying = text(f["unsatisfying"])
        contract = text(f["contract"])
    }

    public static let fieldNames = [
        "identity", "time", "location", "stackAfter", "twoMinute", "goal", "bundle",
        "reward", "invisible", "unattractive", "difficult", "unsatisfying", "contract",
    ]

    public func value(_ name: String) -> String {
        switch name {
        case "identity": identity
        case "time": time
        case "location": location
        case "stackAfter": stackAfter
        case "twoMinute": twoMinute
        case "goal": goal
        case "bundle": bundle
        case "reward": reward
        case "invisible": invisible
        case "unattractive": unattractive
        case "difficult": difficult
        case "unsatisfying": unsatisfying
        default: contract
        }
    }

    /// True when none of the Atomic Habits fields are filled in. The time
    /// doesn't count: any habit can have one.
    public var isEmpty: Bool {
        Self.fieldNames.allSatisfy { $0 == "time" || value($0).isEmpty }
    }
}

public struct Habit: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    /// 0xAARRGGBB.
    public let color: Int
    /// Key into the app's icon set.
    public let icon: String
    public let kind: HabitKind
    /// 1 = Monday … 7 = Sunday. Habits being broken apply every day.
    public let weekdays: Set<Int>
    public let plan: HabitPlan
    /// Minutes: its length in a calendar app when it has a time.
    public let duration: Int
    /// Send a reminder at the habit's time (when it has one).
    public let remind: Bool
    public let order: Double
    public let createdAt: Date
    public let archived: Bool
    public let deleted: Bool

    public init(id: String, fields f: Fields) {
        self.id = id
        name = text(f["name"])
        color = f["color"]?.int ?? 0xFF4C_AF50
        icon = f["icon"]?.string ?? "check"
        kind = f["kind"]?.string == "quit" ? .quit : .build
        weekdays = Set((f["weekdays"]?.array ?? [1, 2, 3, 4, 5, 6, 7]).compactMap(\.int))
        plan = HabitPlan(f)
        duration = f["duration"]?.int ?? 15
        remind = f["remind"]?.bool ?? true
        order = f["order"]?.number ?? 0
        createdAt = f["createdAt"]?.string.flatMap(Timestamp.parse)
            ?? Days.calendar.date(from: DateComponents(year: 2000, month: 1, day: 1))!
        archived = f["archived"]?.bool == true
        deleted = isDeleted(f)
    }

    public var isQuit: Bool { kind == .quit }

    public func isScheduled(_ day: Date) -> Bool {
        isQuit || weekdays.contains(Days.weekday(day))
    }

    /// One check-in row per habit per day, so two devices checking in on the
    /// same day write the same row.
    public static func checkId(_ habitId: String, _ day: Date) -> String {
        "\(habitId)@\(Days.key(day))"
    }

    public var startDay: Date { Days.start(createdAt) }

    /// Scheduled days done in a row, ending today. If today isn't done yet,
    /// it counts up to yesterday so the streak doesn't reset each morning.
    /// With `forgiving` ("never miss twice"), one missed day doesn't end it.
    public func streak(isDone: (Date) -> Bool, today: Date, forgiving: Bool = false) -> Int {
        var day = Days.start(today)
        if !isDone(day) { day = Days.add(day, -1) }
        let start = startDay
        var count = 0
        var missedLast = false
        var i = 0
        while i < 3660 && day >= start {
            defer {
                i += 1
                day = Days.add(day, -1)
            }
            guard isScheduled(day) else { continue }
            if isDone(day) {
                count += 1
                missedLast = false
            } else if forgiving && !missedLast {
                missedLast = true
            } else {
                break
            }
        }
        return count
    }

    /// The last scheduled day before today was missed, and today isn't done:
    /// the moment "never miss twice" is about.
    public func missedLastTime(isDone: (Date) -> Bool, today: Date) -> Bool {
        let t = Days.start(today)
        if isDone(t) { return false }
        var day = Days.add(t, -1)
        while day >= startDay {
            if isScheduled(day) { return !isDone(day) }
            day = Days.add(day, -1)
        }
        return false
    }
}

/// A line on the habits scorecard, rated "+", "-" or "=".
public struct ScorecardItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let text: String
    public let rating: String
    public let order: Double
    public let deleted: Bool

    public init(id: String, fields f: Fields) {
        self.id = id
        text = f["text"]?.string ?? ""
        rating = f["rating"]?.string ?? "="
        order = f["order"]?.number ?? 0
        deleted = isDeleted(f)
    }
}

/// A weekly reflection. The row id is the day key of the week's first day.
public struct WeeklyReview: Sendable {
    public let id: String
    public let answers: [String: String]

    public init(id: String, fields f: Fields) {
        self.id = id
        var answers: [String: String] = [:]
        for (k, v) in f where k != deletedField {
            if let s = v.string { answers[k] = s }
        }
        self.answers = answers
    }

    public static let prompts: [(id: String, text: String)] = [
        ("wentWell", "What went well this week?"),
        ("didntGoWell", "What didn't go so well?"),
        ("improve", "What will you change next week?"),
        ("identity", "What did you do this week that fits the person you want to be?"),
    ]
}

public struct FocusSession: Identifiable, Sendable, Hashable {
    public let id: String
    /// The habit the session was spent on, if one was picked.
    public let habitId: String?
    public let start: Date
    public let minutes: Int
    public let deleted: Bool

    public init(id: String, fields f: Fields) {
        self.id = id
        habitId = f["habitId"]?.string
        start = f["start"]?.string.flatMap(Timestamp.parse) ?? Date(timeIntervalSince1970: 946_684_800)
        minutes = f["minutes"]?.int ?? 0
        deleted = isDeleted(f)
    }
}
