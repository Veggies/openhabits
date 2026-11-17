#if DEBUG
import HabitsCore
import SwiftUI

/// For trying the app out during development. Launch with
/// `-sampleData YES` to start from a fresh, separate database of sample
/// habits (see AppModel.init) and skip
/// setup, and `-startTab progress` (habits, progress, reflect, focus,
/// settings) to open on a tab. On the habits tab, `-openScreen checkIn`
/// or `-openScreen editor` opens that sheet. Not part of release builds.
extension AppModel {
    func applyDebugLaunchOptions() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "sampleData") && repo.habits.isEmpty {
            addSampleHabits()
            onboarded = true
        }
        #if os(macOS)
        // -cycleTabs YES: flips between Today and Progress a few times, to
        // measure tab switching under a profiler.
        if defaults.bool(forKey: "cycleTabs") {
            Task { @MainActor in
                for i in 0..<12 {
                    try? await Task.sleep(for: .seconds(1.2))
                    macTab = i.isMultiple(of: 2) ? .progress : .today
                }
                NSApp.terminate(nil)
            }
        }
        switch defaults.string(forKey: "startTab") {
        case "progress": macTab = .progress
        case "reflect": macTab = .reflect
        case "focus": macTab = .focus
        default: break
        }
        #endif
        switch defaults.string(forKey: "startTab") {
        case "progress": tab = .progress
        case "reflect": tab = .reflect
        case "focus": tab = .focus
        case "settings": tab = .settings
        default: break
        }
    }

    private func addSampleHabits() {
        let today = repo.today
        let all: JSONValue = [1, 2, 3, 4, 5, 6, 7]
        // name, icon, colour, version for now, after I…, time, days,
        // skip every nth day (0 = never), missed yesterday
        let specs: [(String, String, Int, String, String, String, JSONValue, Int, Bool)] = [
            ("Read", "book", habitColors[1], "Read one page", "pour my morning coffee", "21:00", all, 0, false),
            ("Walk", "walk", habitColors[7], "", "", "07:30", [1, 2, 3, 4, 5], 4, false),
            ("Meditate", "yoga", habitColors[2], "One deep breath", "brush my teeth", "", all, 5, false),
            ("Drink water", "water", habitColors[10], "One glass", "wake up", "", all, 3, false),
            ("Journal", "journal", habitColors[11], "Write one line", "get into bed", "22:00", all, 2, true),
            ("Gym", "gym", habitColors[5], "Put on my gym clothes", "", "18:00", [1, 3, 5], 6, false),
        ]
        for (name, icon, color, small, after, time, days, skip, missed) in specs {
            let id = repo.createHabit([
                "name": .string(name), "icon": .string(icon), "color": .int(color),
                "twoMinute": .string(small), "stackAfter": .string(after), "time": .string(time),
                "weekdays": days, "identity": name == "Read" ? "a reader" : "",
            ])
            repo.updateHabit(id, ["createdAt": .string(Timestamp.format(Days.add(today, -60)))])
            for d in 1..<60 {
                if skip > 0 && d % skip == 0 { continue }
                if missed && d == 1 { continue }
                repo.setDone(id, Days.add(today, -d), true)
            }
        }
        if let read = repo.habits.first(where: { $0.name == "Read" }) {
            repo.updateHabit(read.id, ["twoMinute": "Read five pages", "steppedUpAt": .string(Days.key(Days.add(today, -20))),
                "sizeHistory": [
                    ["text": "Read one page", "since": .string(Days.key(Days.add(today, -60)))],
                    ["text": "Read five pages", "since": .string(Days.key(Days.add(today, -20)))],
                ]])
        }
        let quit = repo.createHabit([
            "name": "Scrolling in bed", "icon": "no-phone", "color": .int(habitColors[4]), "kind": "quit",
            "invisible": "Charge my phone outside the bedroom",
        ])
        repo.updateHabit(quit, ["createdAt": .string(Timestamp.format(Days.add(today, -30)))])
        for d in 1..<30 where d != 12 && d != 13 { repo.setDone(quit, Days.add(today, -d), true) }
        for (i, text) in ["Wake up", "Check my phone", "Make coffee", "Go for a walk"].enumerated() {
            repo.addScorecardItem(text)
            if let item = repo.scorecard.last { repo.rateScorecardItem(item.id, ["=", "-", "=", "+"][i]) }
        }
        let now = Date()
        for d in 0..<5 {
            repo.recordFocus(start: Days.add(now, -d).addingTimeInterval(-3600), minutes: 25,
                habitId: d % 2 == 0 ? repo.habits.first?.id : nil)
        }
    }
}
#endif
