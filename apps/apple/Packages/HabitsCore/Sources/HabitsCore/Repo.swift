import Foundation

/// What a size check-in offers: `grow` asks whether a habit that's sticking
/// feels too easy; `shrink` offers to make an often-missed habit smaller.
public enum SizeSuggestion: Sendable { case grow, shrink }

/// How well a habit is going over the last four weeks.
public enum StrengthLevel: Sendable {
    case justStarted, strong, gettingThere, struggling

    public var label: String {
        switch self {
        case .justStarted: "Just started"
        case .strong: "Going strong"
        case .gettingThere: "Getting there"
        case .struggling: "Struggling"
        }
    }
}

public struct Strength: Sendable {
    public let done: Int
    public let scheduled: Int
    public let level: StrengthLevel
}

/// Typed reads and writes over the `LocalStore`, and the habit rules.
/// Matches apps/client/lib/data/repo.dart.
@MainActor
public final class Repo {
    public let store: LocalStore
    public let clock: () -> Date

    public init(store: LocalStore, clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.clock = clock
    }

    public var today: Date { Days.start(clock()) }

    // Results worked out from the data are kept until it changes (or the
    // day does), since screens ask for the same streaks again and again.
    private var memoRevision = -1
    private var memoDay = ""
    private var memo: [String: Any] = [:]
    private var cachedHabits: [Habit]?

    private func remember<T>(_ key: String, _ work: () -> T) -> T {
        let revision = store.revision  // also lets screens update when it changes
        let day = Days.key(clock())
        if revision != memoRevision || day != memoDay {
            memoRevision = revision
            memoDay = day
            memo = [:]
            cachedHabits = nil
        }
        // Look the key up first: a missing entry would otherwise pass as a
        // remembered nil when T is optional.
        if let i = memo.index(forKey: key), let value = memo[i].value as? T { return value }
        let value = work()
        memo[key] = value
        return value
    }

    // MARK: Habits

    /// Active habits (not archived or deleted), in order.
    public var habits: [Habit] {
        remember("habits") {
            store.table(Tables.habits)
                .map { Habit(id: $0.key, fields: $0.value) }
                .filter { !$0.deleted && !$0.archived }
                .sorted { $0.order < $1.order }
        }
    }

    public func habit(_ id: String) -> Habit? {
        store.row(Tables.habits, id).map { Habit(id: id, fields: $0) }
    }

    @discardableResult
    public func createHabit(_ fields: Fields) -> String {
        let id = store.newId()
        let now = clock()
        var all = fields
        all["order"] = .double((now.timeIntervalSince1970 * 1000).rounded())
        all["createdAt"] = .string(Timestamp.format(now))
        store.write(Tables.habits, id, all)
        return id
    }

    public func updateHabit(_ id: String, _ fields: Fields) {
        store.write(Tables.habits, id, fields)
    }

    public func deleteHabit(_ id: String) {
        store.write(Tables.habits, id, [deletedField: true])
    }

    public func isDone(_ habitId: String, _ day: Date) -> Bool {
        store.row(Tables.habitChecks, Habit.checkId(habitId, day))?["done"]?.bool == true
    }

    /// The habit has the day off, so the day isn't missed. A day that was
    /// done anyway counts as done.
    public func isOff(_ habitId: String, _ day: Date) -> Bool {
        guard let row = store.row(Tables.habitChecks, Habit.checkId(habitId, day)) else { return false }
        return row[Habit.offField]?.bool == true && row["done"]?.bool != true
    }

    /// Checks a habit in for a day. For a habit being broken, a check-in
    /// means "I stayed clear today". Checking in or out ends a day off, so
    /// unticking a day doesn't bring one back.
    public func setDone(_ habitId: String, _ day: Date, _ done: Bool) {
        let row = store.row(Tables.habitChecks, Habit.checkId(habitId, day))
        var fields: Fields = [
            "habitId": .string(habitId), "date": .string(Days.key(day)), "done": .bool(done),
        ]
        if row?[Habit.offField]?.bool == true { fields[Habit.offField] = .bool(false) }
        store.write(Tables.habitChecks, Habit.checkId(habitId, day), fields)
    }

    /// Gives a habit the day off, or takes it back. It doesn't count as
    /// missed, and the streak carries on past it. A day that's done stays
    /// done, and this never writes `done`, so it can't undo a check-in made
    /// on another device before the two synced.
    public func setOff(_ habitId: String, _ day: Date, _ off: Bool) {
        guard !isDone(habitId, day) else { return }
        store.write(Tables.habitChecks, Habit.checkId(habitId, day), [
            "habitId": .string(habitId), "date": .string(Days.key(day)), Habit.offField: .bool(off),
        ])
    }

    public func toggle(_ habitId: String, _ day: Date) {
        setDone(habitId, day, !isDone(habitId, day))
    }

    /// Scheduled days done in a row. One missed day is forgiven ("never
    /// miss twice").
    public func streak(_ h: Habit) -> Int {
        remember("streak\(h.id)") {
            h.streak(isDone: { isDone(h.id, $0) }, today: clock(), forgiving: true, isOff: { isOff(h.id, $0) })
        }
    }

    /// For habits being broken: the run of days marked clear.
    public func daysClean(_ h: Habit) -> Int {
        remember("clean\(h.id)") { h.streak(isDone: { isDone(h.id, $0) }, today: clock(), isOff: { isOff(h.id, $0) }) }
    }

    public func missedLastTime(_ h: Habit) -> Bool {
        remember("missed\(h.id)") { h.missedLastTime(isDone: { isDone(h.id, $0) }, today: clock(), isOff: { isOff(h.id, $0) }) }
    }

    /// Scheduled days done, out of scheduled days, in the `days` up to and
    /// including `end`, counting only days since the habit started.
    public func record(_ h: Habit, end: Date, days: Int) -> (done: Int, scheduled: Int) {
        h.record(isDone: { isDone(h.id, $0) }, end: end, days: days, isOff: { isOff(h.id, $0) })
    }

    public func completionRate(_ h: Habit, end: Date, days: Int) -> Double {
        let r = record(h, end: end, days: days)
        return r.scheduled == 0 ? 0 : Double(r.done) / Double(r.scheduled)
    }

    /// For the Progress grid: days done out of days due in the week starting
    /// `weekStart`, up to today.
    public func weekRecord(_ h: Habit, weekStart: Date) -> (done: Int, scheduled: Int) {
        let r: [Int] = remember("week\(h.id)\(weekStart.timeIntervalSince1970)") {
            let w = computeWeekRecord(h, weekStart: weekStart)
            return [w.done, w.scheduled]
        }
        return (r[0], r[1])
    }

    private func computeWeekRecord(_ h: Habit, weekStart: Date) -> (done: Int, scheduled: Int) {
        let weekEnd = Days.add(Days.start(weekStart), 6)
        let end = min(weekEnd, today)
        if end < weekStart { return (0, 0) }
        return record(h, end: end, days: Days.between(weekStart, end) + 1)
    }

    /// Total check-ins: each one is a vote for the habit's identity.
    public func votes(_ habitId: String) -> Int {
        store.table(Tables.habitChecks).values
            .filter { $0["habitId"]?.string == habitId && $0["done"]?.bool == true }.count
    }

    /// How it's gone over the last four weeks. The thresholds match the size
    /// check-ins: 80% is "most days". Under a week old is too soon to say.
    public func strength(_ h: Habit) -> Strength {
        remember("strength\(h.id)") { computeStrength(h) }
    }

    private func computeStrength(_ h: Habit) -> Strength {
        let r = record(h, end: today, days: 28)
        let level: StrengthLevel =
            r.scheduled == 0 || Days.between(h.startDay, today) < 7 ? .justStarted
            : r.done >= Self.growDaysNeeded(r.scheduled) ? .strong
            : r.done * 2 >= r.scheduled ? .gettingThere
            : .struggling
        return Strength(done: r.done, scheduled: r.scheduled, level: level)
    }

    // MARK: Start small and grow it

    /// The Goldilocks rule. Done on most scheduled days (80%) over two weeks
    /// means it's sticking, so ask whether it feels too easy; done on under
    /// half suggests making it smaller. Otherwise nothing.
    public func sizeSuggestion(_ h: Habit) -> SizeSuggestion? {
        let result: SizeSuggestion?? = remember("size\(h.id)") { .some(computeSizeSuggestion(h)) }
        return result ?? nil
    }

    private func computeSizeSuggestion(_ h: Habit) -> SizeSuggestion? {
        let plan = h.plan
        guard !h.isQuit, !plan.twoMinute.isEmpty, !plan.sizeSettled else { return nil }
        let since = Days.parse(plan.steppedUpAt) ?? h.startDay
        guard Days.between(since, today) >= 14 else { return nil }
        let r = record(h, end: today, days: 14)
        guard r.scheduled > 0 else { return nil }
        if r.done >= Self.growDaysNeeded(r.scheduled) { return .grow }
        if r.done * 2 < r.scheduled { return .shrink }
        return nil
    }

    /// 80% of scheduled days, rounded up: 12 of 14, 8 of 10, 5 of 6.
    public static func growDaysNeeded(_ scheduled: Int) -> Int { (scheduled * 4 + 4) / 5 }

    /// The fields that change a habit's version to `next` and start a new
    /// two-week period. Empty if nothing changes.
    public func resizeFields(_ h: Habit, to next: String) -> Fields {
        let next = next.trimmingCharacters(in: .whitespacesAndNewlines)
        let plan = h.plan
        guard !next.isEmpty, next != plan.twoMinute else { return [:] }
        let todayKey = Days.key(clock())
        var history: [JSONValue] = []
        if plan.sizeHistory.isEmpty && !plan.twoMinute.isEmpty {
            history.append(["text": .string(plan.twoMinute), "since": .string(Days.key(h.createdAt))])
        }
        for v in plan.sizeHistory {
            history.append(["text": .string(v.text), "since": .string(v.since)])
        }
        history.append(["text": .string(next), "since": .string(todayKey)])
        return ["twoMinute": .string(next), "steppedUpAt": .string(todayKey), "sizeHistory": .array(history)]
    }

    public func resize(_ h: Habit, to next: String) { updateHabit(h.id, resizeFields(h, to: next)) }

    /// "Keep it as it is": check in again in two weeks.
    public func keepSize(_ h: Habit) {
        updateHabit(h.id, ["steppedUpAt": .string(Days.key(clock()))])
    }

    /// "This feels right, stop asking", or with `settled` false, start
    /// checking in again from today.
    public func settleSize(_ h: Habit, settled: Bool = true) {
        updateHabit(h.id, ["sizeSettled": .bool(settled), "steppedUpAt": .string(Days.key(clock()))])
    }

    // MARK: Preferences

    public var prefs: Prefs { Prefs(store.row(Tables.prefs, Prefs.rowId)) }
    public func setPrefs(_ fields: Fields) { store.write(Tables.prefs, Prefs.rowId, fields) }
    public var weekStart: Int { prefs.weekStart }

    // MARK: Scorecard and weekly review

    public var scorecard: [ScorecardItem] {
        store.table(Tables.scorecard)
            .map { ScorecardItem(id: $0.key, fields: $0.value) }
            .filter { !$0.deleted }
            .sorted { $0.order < $1.order }
    }

    public func addScorecardItem(_ text: String) {
        store.write(Tables.scorecard, store.newId(), [
            "text": .string(text), "rating": "=",
            "order": .double((clock().timeIntervalSince1970 * 1000).rounded()),
        ])
    }

    public func rateScorecardItem(_ id: String, _ rating: String) {
        store.write(Tables.scorecard, id, ["rating": .string(rating)])
    }

    public func deleteScorecardItem(_ id: String) {
        store.write(Tables.scorecard, id, [deletedField: true])
    }

    /// The review for the week containing `day`.
    public func review(_ day: Date) -> WeeklyReview {
        let id = Days.key(Days.startOfWeek(day, firstDay: weekStart))
        return WeeklyReview(id: id, fields: store.row(Tables.reviews, id) ?? [:])
    }

    public func saveReview(_ day: Date, prompt: String, answer: String) {
        store.write(Tables.reviews, Days.key(Days.startOfWeek(day, firstDay: weekStart)),
            [prompt: .string(answer)])
    }

    /// Last week's review hasn't been written yet.
    public var lastWeekReviewDue: Bool {
        let all = habits
        guard !all.isEmpty else { return false }
        let thisWeek = Days.startOfWeek(clock(), firstDay: weekStart)
        return all.contains { $0.createdAt < thisWeek }
            && review(Days.add(thisWeek, -7)).answers.isEmpty
    }

    // MARK: Focus

    public var focusSessions: [FocusSession] {
        store.table(Tables.focusSessions)
            .map { FocusSession(id: $0.key, fields: $0.value) }
            .filter { !$0.deleted }
            .sorted { $0.start > $1.start }
    }

    public func recordFocus(start: Date, minutes: Int, habitId: String?) {
        store.write(Tables.focusSessions, store.newId(), [
            "start": .string(Timestamp.format(start)),
            "minutes": .int(minutes),
            "habitId": habitId.map(JSONValue.string) ?? .null,
        ])
    }
}
