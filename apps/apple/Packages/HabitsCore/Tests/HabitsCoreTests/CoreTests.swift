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
        // Any punctuation after the lead counts, except an apostrophe.
        #expect(HabitPlan.tidy("stackAfter", "After I: sit down") == "sit down")
        #expect(HabitPlan.tidy("stackAfter", "After I; sit down") == "sit down")
        #expect(HabitPlan.tidy("stackAfter", "After I – sit down") == "sit down")
        #expect(HabitPlan.tidy("identity", "I am: a reader") == "a reader")
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

    @Test(arguments: try daysOffCases())
    func daysOff(_ value: JSONValue) throws {
        let c = value.object!
        let f = try fixture("days_off.json")
        let now = Days.parse(f["today"]!.string!)!
        let h = Habit(id: "h", fields: [
            "weekdays": c["weekdays"]!, "createdAt": .string(Timestamp.format(Days.parse(f["created"]!.string!)!)),
        ])
        func on(_ key: String) -> (Date) -> Bool {
            let days = Set(c[key]!.array!.compactMap { $0.int })
            return { Days.calendar.component(.month, from: $0) == 11 && days.contains(Days.calendar.component(.day, from: $0)) }
        }
        let done = on("done"), off = on("off")
        let name = c["name"]!.string!
        #expect(h.streak(isDone: done, today: now, isOff: off) == c["streak"]!.int, "\(name)")
        #expect(h.streak(isDone: done, today: now, forgiving: true, isOff: off) == c["forgivingStreak"]!.int, "\(name)")
        #expect(h.missedLastTime(isDone: done, today: now, isOff: off) == c["missedLastTime"]!.bool, "\(name)")
        let r = h.record(isDone: done, end: now, days: 7, isOff: off)
        #expect([r.done, r.scheduled] == c["record"]!.array!.compactMap { $0.int }, "\(name)")
    }

    @Test func aDayOffIsSavedAndEndsWhenDone() throws {
        let r = try repo()
        let h = habit(r)
        for d in [0, 1, 3] { r.setDone(h.id, Days.add(today, -d), true) }
        r.setOff(h.id, Days.add(today, -2), true)
        #expect(r.isOff(h.id, Days.add(today, -2)))
        #expect(r.streak(h) == 3)
        #expect(r.daysClean(h) == 3)
        r.setDone(h.id, Days.add(today, -2), true)
        #expect(!r.isOff(h.id, Days.add(today, -2)))
        #expect(r.streak(h) == 4)
        r.setOff(h.id, Days.add(today, -2), false)
        #expect(r.streak(h) == 4)  // a done day stays done
        r.setDone(h.id, Days.add(today, -2), false)
        #expect(r.streak(h) == 3)  // back to a plain miss, forgiven once
    }

    @Test func aDayOffNeverUndoesACheckIn() throws {
        let r = try repo()
        let h = habit(r)
        let day = Days.add(today, -1)
        r.setOff(h.id, day, true)
        // Taking a day off writes only the off field, so it can't overwrite
        // a check-in from another device when the two sync.
        let id = Habit.checkId(h.id, day)
        #expect(r.store.row(Tables.habitChecks, id)?["done"] == nil)
        // As if a check-in arrived from another device: done and off.
        r.store.write(Tables.habitChecks, id, ["done": true])
        #expect(!r.isOff(h.id, day))
        r.setOff(h.id, day, true)
        #expect(r.isDone(h.id, day))
        // Unticking it doesn't bring the day off back.
        r.setDone(h.id, day, false)
        #expect(!r.isOff(h.id, day))
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

func daysOffCases() throws -> [JSONValue] { try fixture("days_off.json")["cases"]!.array! }

@MainActor
@Suite struct Rewards {
    @Test func rewardsReadTheirNameAndPrice() throws {
        let f = try fixture("rewards.json")
        for r in f["rewards"]!.array! {
            let o = r.object!
            let reward = Reward(id: o["id"]!.string!, fields: o["fields"]!.object!)
            #expect(reward.cost == o["cost"]!.int, "\(reward.id)")
            #expect(reward.name == o["fields"]!.object!["name"]!.string)
        }
    }

    @Test(arguments: try fixture("rewards.json")["cases"]!.array!)
    func tomatoesLeft(_ value: JSONValue) throws {
        let c = value.object!
        let today = try fixture("rewards.json")["today"]!.string!
        let spends = c["spends"]!.array!.enumerated().map { RewardSpend(id: "s\($0.offset)", fields: $0.element.object!) }
        #expect(tomatoesToSpend(earnedToday: c["earned"]!.int!, spends: spends, todayKey: today) == c["toSpend"]!.int,
            "\(c["name"]!.string!)")
    }

    @Test func spendingAndTakingBack() throws {
        let store = try LocalStore()
        let now = Days.parse("2026-11-27")!.addingTimeInterval(15 * 3600)
        let r = Repo(store: store, clock: { now })
        let show = r.addReward(name: " An episode of a show ", cost: 4)
        let reward = r.rewards.first { $0.id == show }!
        #expect(reward.name == "An episode of a show")
        for h in [9, 10, 11] { r.recordFocus(start: Days.parse("2026-11-27")!.addingTimeInterval(Double(h) * 3600), minutes: 25, habitId: nil) }
        r.recordFocus(start: Days.parse("2026-11-26")!.addingTimeInterval(9 * 3600), minutes: 25, habitId: nil)
        #expect(r.tomatoesToday == 3)  // yesterday's doesn't count
        r.spend(on: reward)
        #expect(r.rewardSpends.isEmpty)  // not enough yet
        r.recordFocus(start: now, minutes: 25, habitId: nil)
        let trip = r.addReward(name: "A day trip", cost: 20)
        #expect(r.rewardsReady.map(\.id) == [show])  // the trip is too dear
        _ = trip
        r.spend(on: reward)
        #expect(r.rewardsReady.isEmpty)
        #expect(r.tomatoesToSpend == 0)
        #expect(r.rewardSpends.first?.name == "An episode of a show")
        // Renaming the reward doesn't change what was spent.
        r.updateReward(show, name: "Two episodes", cost: 8)
        #expect(r.rewardSpends.first?.cost == 4)
        r.takeBack(r.rewardSpends[0])
        #expect(r.tomatoesToSpend == 4)
    }
}

@MainActor @Suite struct Tasks {
    @Test(arguments: try fixture("tasks.json")["tasks"]!.array!)
    func readsAndPlacesTask(_ value: JSONValue) throws {
        let c = value.object!
        let today = Days.parse(try fixture("tasks.json")["today"]!.string!)!
        let fields = c["fields"]!.object!
        let t = TaskItem(id: c["id"]!.string!, fields: fields)
        let name = c["id"]!.string!
        #expect(t.title == (fields["title"]?.string ?? ""), "\(name)")
        #expect(t.due == c["due"]!.string, "\(name)")
        #expect("\(taskGroup(t, today: today))" == c["group"]!.string, "\(name)")
        #expect(dueLabel(t, today: today) == c["label"]!.string, "\(name)")
        #expect("\(taskQuadrant(t))" == c["quadrant"]!.string, "\(name)")
    }

    @Test func addingTickingOffAndDeleting() throws {
        let store = try LocalStore()
        var now = Days.parse("2026-11-28")!.addingTimeInterval(9 * 3600)
        let r = Repo(store: store, clock: { now })
        let today = r.today
        let rent = r.addTask(title: " Pay the rent ", due: today, important: true, urgent: true)
        let juggle = r.addTask(title: "Learn to juggle")
        let dentist = r.addTask(title: "Call the dentist", due: Days.add(today, 1))
        let late = r.addTask(title: "Return the library book", due: Days.add(today, -3))
        #expect(r.tasks.first { $0.id == rent }?.title == "Pay the rent")
        #expect(r.tasks(in: .today).map(\.id) == [rent, late])  // important first, then by date
        #expect(r.tasks(in: .upcoming).map(\.id) == [dentist])
        #expect(r.tasks(in: .someday).map(\.id) == [juggle])
        #expect(r.tasks(in: .doNow).map(\.id) == [rent])
        #expect(r.tasksForToday.map(\.id) == [rent, late])

        r.setTaskDone(rent, true)
        #expect(r.tasks(in: .done).map(\.id) == [rent])
        #expect(r.tasks(in: .doNow).isEmpty)
        #expect(r.tasksForToday.map(\.id) == [late, rent])  // still shows today, after the rest
        r.setTaskDone(rent, false)
        #expect(r.tasks.first { $0.id == rent }?.doneAt == nil)

        // Taking the date away moves it to someday.
        r.updateTask(dentist, title: "Call the dentist", due: nil, important: false, urgent: true)
        #expect(r.tasks(in: .someday).map(\.id) == [dentist, juggle])  // urgent first
        #expect(r.tasks(in: .keepQuick).map(\.id) == [dentist])

        r.deleteTask(juggle)
        #expect(!r.tasks.contains { $0.id == juggle })

        // The next day, yesterday's finished task drops off Today.
        r.setTaskDone(late, true)
        now = Days.add(today, 1).addingTimeInterval(9 * 3600)
        #expect(r.tasksForToday.map(\.id) == [rent])  // due yesterday, so overdue now
    }
}
