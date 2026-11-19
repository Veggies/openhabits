import Foundation
import Testing

@testable import HabitsCore

@Suite struct ClockAndMerge {
    @Test func packedTimestampsSortLikeTheClock() {
        let a = HLC(1_700_000_000_000, 0, "aa")
        let b = HLC(1_700_000_000_000, 15, "aa")
        let c = HLC(1_700_000_000_001, 0, "aa")
        #expect(a.pack() == "001700000000000-0000-aa")
        #expect(b.pack() == "001700000000000-000f-aa")
        #expect([c, a, b].sorted() == [a, b, c])
        #expect([c, a, b].map { $0.pack() }.sorted() == [a, b, c].map { $0.pack() })
        #expect(HLC.parse(b.pack()) == b)
        // Node ids may contain dashes.
        #expect(HLC.parse("001700000000000-0001-ab-cd")?.nodeId == "ab-cd")
    }

    @Test func sendAndReceive() {
        let clock = HLC(100, 0, "me")
        #expect(clock.send(50) == HLC(100, 1, "me"))
        #expect(clock.send(200) == HLC(200, 0, "me"))
        #expect(clock.receive(HLC(300, 4, "you"), 150) == HLC(300, 5, "me"))
        #expect(clock.receive(HLC(100, 7, "you"), 50) == HLC(100, 8, "me"))
    }

    @Test func latestWriteWinsAndDuplicatesAreIgnored() {
        let old = HLC(1, 0, "a"), new = HLC(2, 0, "a")
        #expect(shouldApply(old, over: nil))
        #expect(shouldApply(new, over: old))
        #expect(!shouldApply(old, over: new))
        #expect(!shouldApply(new, over: new))
    }

    @Test func changesRoundTripAsTheServerExpects() throws {
        let json = #"{"table":"habits","rowId":"r1","field":"order","value":1731700000000.0,"hlc":"001700000000000-0000-aa"}"#
        let c = try JSONDecoder().decode(Change.self, from: Data(json.utf8))
        #expect(c.value.number == 1_731_700_000_000)
        let back = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        #expect(back.contains(#""hlc":"001700000000000-0000-aa""#))
        // Whole numbers stay whole, so Dart reads them back as ints.
        #expect(JSONValue.int(25).encoded() == "25")
        #expect(JSONValue.decode("[1,2,3]") == .array([.int(1), .int(2), .int(3)]))
        #expect(JSONValue.decode("true") == .bool(true))
        // A missing value means null.
        let noValue = #"{"table":"t","rowId":"r","field":"f","hlc":"001700000000000-0000-aa"}"#
        #expect(try JSONDecoder().decode(Change.self, from: Data(noValue.utf8)).value == .null)
    }
}

@Suite struct DatesAndTimes {
    @Test func leadWordsTypedIntoThePlanAreNotDoubled() {
        #expect(HabitPlan.tidy("stackAfter", " After I sit down ") == "sit down")
        #expect(HabitPlan.tidy("stackAfter", "after i, pour coffee") == "pour coffee")
        #expect(HabitPlan.tidy("stackAfter", "pour coffee") == "pour coffee")
        #expect(HabitPlan.tidy("identity", "I am a reader") == "a reader")
        #expect(HabitPlan.tidy("identity", "I amaze people") == "I amaze people")
        #expect(HabitPlan.tidy("location", "After I leave") == "After I leave")
        // Contractions keep their verb, so the plan still reads "After I have…".
        #expect(HabitPlan.tidy("stackAfter", "After I've finished breakfast") == "have finished breakfast")
        #expect(HabitPlan.tidy("stackAfter", "After I’m home") == "am home")
        #expect(HabitPlan.tidy("identity", "I'm a runner") == "a runner")
        // The lead only counts as whole words, so names are left alone.
        #expect(HabitPlan.tidy("stackAfter", "After Iñaki leaves") == "After Iñaki leaves")
        // Typed twice, both copies come off.
        #expect(HabitPlan.tidy("stackAfter", "After I After I sit down") == "sit down")
        // Plans saved before the fix read back without the doubled words.
        #expect(HabitPlan(["stackAfter": "After I sit down"]).stackAfter == "sit down")
    }

    @Test func dayKeysAndWeekdays() {
        let day = Days.parse("2026-11-15")!  // a Sunday
        #expect(Days.key(day) == "2026-11-15")
        #expect(Days.weekday(day) == 7)
        #expect(Days.weekday(Days.add(day, 1)) == 1)
        #expect(Days.key(Days.startOfWeek(day, firstDay: Days.sunday)) == "2026-11-15")
        #expect(Days.key(Days.startOfWeek(day, firstDay: Days.monday)) == "2026-11-09")
        #expect(Days.between(Days.parse("2026-03-01")!, Days.parse("2026-04-01")!) == 31)
        #expect(Days.key(Days.addMonths(Days.parse("2026-01-31")!, 1)) == "2026-02-28")
        #expect(Days.order(startingOn: Days.sunday) == [7, 1, 2, 3, 4, 5, 6])
    }

    @Test func readsDartTimestamps() {
        let micro = Timestamp.parse("2026-11-15T07:48:12.123456Z")!
        let milli = Timestamp.parse("2026-11-15T07:48:12.123Z")!
        let plain = Timestamp.parse("2026-11-15T07:48:12Z")!
        #expect(abs(micro.timeIntervalSince(plain) - 0.123456) < 0.000_01)
        #expect(abs(milli.timeIntervalSince(plain) - 0.123) < 0.000_01)
        let written = Timestamp.format(milli)
        #expect(written == "2026-11-15T07:48:12.123Z")
        #expect(Timestamp.parse("2026-11-15T09:48:12+02:00") == plain)
    }
}

@MainActor
@Suite struct HabitRules {
    let today = Days.parse("2026-11-15")!

    func repo() throws -> Repo {
        let store = try LocalStore()
        let now = today.addingTimeInterval(12 * 3600)
        return Repo(store: store, clock: { now })
    }

    func habit(_ repo: Repo, _ fields: Fields = [:], daysOld: Int = 40) -> Habit {
        var f: Fields = ["name": "Read"]
        f.merge(fields) { _, b in b }
        let id = repo.createHabit(f)
        repo.updateHabit(id, ["createdAt": .string(Timestamp.format(Days.add(today, -daysOld)))])
        return repo.habit(id)!
    }

    @Test func oneMissedDayIsForgiven() throws {
        let r = try repo()
        let h = habit(r)
        for d in [0, 1, 3, 4, 5, 6, 7, 8] { r.setDone(h.id, Days.add(today, -d), true) }
        #expect(r.streak(h) == 8)  // day 2 alone is forgiven ("never miss twice")
        r.setDone(h.id, Days.add(today, -5), false)
        r.setDone(h.id, Days.add(today, -6), false)
        #expect(r.streak(h) == 4)  // two misses in a row end it: days 7 and 8 drop out
        r.setDone(h.id, today, false)
        #expect(r.streak(h) == 3)  // today not done yet: counts from yesterday
    }

    @Test func unscheduledDaysDontBreakAStreak() throws {
        let r = try repo()
        // Weekdays only; today is a Sunday.
        let h = habit(r, ["weekdays": [1, 2, 3, 4, 5]])
        for d in 2...6 { r.setDone(h.id, Days.add(today, -d), true) }
        #expect(r.streak(h) == 5)
        #expect(!r.missedLastTime(h))
        r.setDone(h.id, Days.add(today, -2), false)  // Friday
        #expect(r.missedLastTime(h))
    }

    @Test func breakingAHabitCountsDaysClear() throws {
        let r = try repo()
        let h = habit(r, ["kind": "quit"])
        for d in 1...5 { r.setDone(h.id, Days.add(today, -d), true) }
        #expect(r.daysClean(h) == 5)
        #expect(h.isScheduled(today))
    }

    @Test func sizeCheckIns() throws {
        let r = try repo()
        let h = habit(r, ["twoMinute": "Read one page"])
        for d in 0..<14 where d != 3 { r.setDone(h.id, Days.add(today, -d), true) }
        #expect(r.sizeSuggestion(h) == .grow)
        r.keepSize(h)
        #expect(r.sizeSuggestion(r.habit(h.id)!) == nil)  // asks again in two weeks

        let fields = r.resizeFields(r.habit(h.id)!, to: " Read five pages ")
        r.updateHabit(h.id, fields)
        let grown = r.habit(h.id)!
        #expect(grown.plan.twoMinute == "Read five pages")
        #expect(grown.plan.sizeHistory.map(\.text) == ["Read one page", "Read five pages"])
        #expect(r.resizeFields(grown, to: "Read five pages").isEmpty)

        let missed = habit(r, ["name": "Walk", "twoMinute": "Put on shoes"])
        r.setDone(missed.id, today, true)
        #expect(r.sizeSuggestion(missed) == .shrink)
        r.settleSize(missed)
        #expect(r.sizeSuggestion(r.habit(missed.id)!) == nil)
    }

    @Test func growNeedsMostDays() {
        #expect(Repo.growDaysNeeded(14) == 12)
        #expect(Repo.growDaysNeeded(10) == 8)
        #expect(Repo.growDaysNeeded(6) == 5)
    }

    @Test func strength() throws {
        let r = try repo()
        let strong = habit(r)
        for d in 0..<28 { r.setDone(strong.id, Days.add(today, -d), true) }
        #expect(r.strength(strong).level == .strong)
        let new = habit(r, daysOld: 3)
        #expect(r.strength(new).level == .justStarted)
        let weak = habit(r)
        #expect(r.strength(weak).level == .struggling)
    }
}

@MainActor
@Suite struct Storage {
    @Test func editsAreSavedAndQueued() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("habits-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try LocalStore(path: path)
        let repo = Repo(store: store)
        let id = repo.createHabit(["name": "Read", "weekdays": [1, 2, 3]])
        #expect(store.pendingCount > 0)

        let reopened = try LocalStore(path: path)
        #expect(reopened.nodeId == store.nodeId)
        let habit = Repo(store: reopened).habit(id)
        #expect(habit?.name == "Read")
        #expect(habit?.weekdays == [1, 2, 3])
        let pending = reopened.pending()
        #expect(pending.changes.count == store.pendingCount)
        reopened.markSent(upTo: pending.lastId)
        #expect(reopened.pendingCount == 0)
    }

    @Test func olderRemoteChangesLose() throws {
        let store = try LocalStore()
        store.write("habits", "h", ["name": "New"])
        try store.applyRemote(
            [Change(table: "habits", rowId: "h", field: "name", value: "Old", hlc: HLC(1, 0, "x"))],
            cursor: 5)
        #expect(store.row("habits", "h")?["name"] == "New")
        #expect(store.cursor == 5)
    }

    @Test func pairingCodes() {
        let p = Pairing(server: "http://192.168.1.10:8080", code: "ABCD-1234",
            remote: "https://1.2.3.4:8443", fingerprint: "AA:BB")
        let back = Pairing(payload: p.payload)
        #expect(back?.server == p.server)
        #expect(back?.code == p.code)
        #expect(back?.remote == p.remote)
        #expect(back?.fingerprint == "AA:BB")
        #expect(Pairing(payload: "https://example.com") == nil)
    }

    @Test func addresses() {
        #expect(SyncEngine.normalize("192.168.1.10:8080/") == "http://192.168.1.10:8080")
        #expect(SyncEngine.normalize("habits.example.com") == "https://habits.example.com")
        #expect(SyncEngine.normalize("localhost:8080") == "http://localhost:8080")
    }
}
