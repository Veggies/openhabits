import HabitsCore
import SwiftUI
import UserNotifications

/// Reminders, scheduled on this device (no server needed, and they work
/// offline):
///
/// - at each habit's set time, with a Mark as Done button, and
/// - a daily check-in at a time you choose, listing what's still left.
///
/// The next week of reminders is worked out whenever habits change or the
/// app opens, so a habit that's already done today doesn't nag. Which kinds
/// are on is kept per device.
@MainActor
@Observable
final class Reminders: NSObject, UNUserNotificationCenterDelegate {
    private let repo: Repo

    /// Reminders at each habit's set time.
    var habitTimes: Bool {
        didSet { save("remindHabitTimes", habitTimes) }
    }
    /// The daily "time to check in" reminder, and when.
    var checkIn: Bool {
        didSet { save("remindCheckIn", checkIn) }
    }
    var checkInTime: Date {
        didSet {
            UserDefaults.standard.set(TimeOfDay(checkInTime).text, forKey: "remindCheckInTime")
            refreshSoon()
        }
    }
    /// The person turned notifications off for the app in the system's
    /// settings.
    private(set) var denied = false

    @ObservationIgnored private var pending: Task<Void, Never>?
    nonisolated private static let habitCategory = "habit"
    nonisolated private static let doneAction = "done"

    init(repo: Repo) {
        self.repo = repo
        let d = UserDefaults.standard
        habitTimes = d.bool(forKey: "remindHabitTimes")
        checkIn = d.bool(forKey: "remindCheckIn")
        checkInTime = TimeOfDay(d.string(forKey: "remindCheckInTime") ?? "20:00")?.date()
            ?? TimeOfDay(hour: 20, minute: 0).date()
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.habitCategory, actions: [
                UNNotificationAction(identifier: Self.doneAction, title: "Mark as Done", options: []),
            ], intentIdentifiers: []),
        ])
    }

    private func save(_ key: String, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
        if on {
            Task {
                let granted = (try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
                denied = !granted
                refreshSoon()
            }
        } else {
            refreshSoon()
        }
    }

    /// Reworks the schedule shortly, so a burst of changes (like a sync)
    /// only does it once.
    func refreshSoon() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func refresh() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        denied = settings.authorizationStatus == .denied
        // Clear what was scheduled before (but not the Focus timer's).
        let old = await center.pendingNotificationRequests().map(\.identifier)
            .filter { $0.hasPrefix("habit-") || $0.hasPrefix("checkin-") }
        center.removePendingNotificationRequests(withIdentifiers: old)
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        else { return }

        var requests: [UNNotificationRequest] = []
        let now = Date()
        let today = Days.start(now)
        let habits = repo.habits

        // As many days ahead as the 60 notifications kept below cover, so
        // reminders keep coming for weeks even if the app isn't opened (it
        // reschedules whenever it is). Matches reminders.dart.
        for offset in 0..<60 {
            let day = Days.add(today, offset)
            if habitTimes {
                for h in habits where !h.isQuit && h.remind && h.isScheduled(day) {
                    guard let time = TimeOfDay(h.plan.time) else { continue }
                    let at = time.date(on: day)
                    guard at > now, !repo.isDone(h.id, day) else { continue }
                    let content = UNMutableNotificationContent()
                    content.title = h.name
                    content.body = habitMessage(h)
                    content.sound = .default
                    content.categoryIdentifier = Self.habitCategory
                    content.userInfo = ["habitId": h.id, "day": Days.key(day)]
                    content.threadIdentifier = "habits"
                    requests.append(request("habit-\(h.id)-\(Days.key(day))", content, at))
                }
            }
            if checkIn {
                let at = TimeOfDay(checkInTime).date(on: day)
                guard at > now else { continue }
                let left = habits.filter { $0.isScheduled(day) && !repo.isDone($0.id, day) }
                // Nothing left today: no need to remind.
                if offset == 0 && left.isEmpty { continue }
                let content = UNMutableNotificationContent()
                content.title = "Time to check in on your habits"
                content.body = offset != 0
                    ? "Take a minute to mark off what you did today."
                    : left.count == 1
                    ? "You haven't marked \(left[0].name) yet today."
                    : "You haven't marked these yet today: \(names(left))."
                content.sound = .default
                content.threadIdentifier = "checkin"
                requests.append(request("checkin-\(Days.key(day))", content, at))
            }
        }
        // The system keeps up to 64 waiting; the soonest matter most.
        for r in requests.sorted(by: { fireDate($0) < fireDate($1) }).prefix(60) {
            try? await center.add(r)
        }
    }

    private func habitMessage(_ h: Habit) -> String {
        let plan = h.plan
        if !plan.stackAfter.isEmpty && !plan.twoMinute.isEmpty {
            return "After you \(plan.stackAfter), \(plan.twoMinute.prefix(1).lowercased() + plan.twoMinute.dropFirst())."
        }
        if !plan.twoMinute.isEmpty { return "Time for \(plan.twoMinute.prefix(1).lowercased() + plan.twoMinute.dropFirst())." }
        return "It's time for this habit."
    }

    private func request(_ id: String, _ content: UNNotificationContent, _ at: Date) -> UNNotificationRequest {
        let parts = Days.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        return UNNotificationRequest(identifier: id, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
    }

    private func fireDate(_ r: UNNotificationRequest) -> Date {
        (r.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantFuture
    }

    // MARK: When a notification arrives or is answered

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions
    {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async
    {
        let info = response.notification.request.content.userInfo
        guard response.actionIdentifier == Self.doneAction,
            let id = info["habitId"] as? String, let key = info["day"] as? String
        else { return }
        await MainActor.run {
            if let day = Days.parse(key) { repo.setDone(id, day, true) }
        }
    }
}
