import HabitsCore
import SwiftUI
import UserNotifications

/// The focus timer. Lives in the app model so it keeps running while you
/// move around. Time is measured against an end time, not by counting
/// ticks, so it stays right if the app is suspended.
@MainActor
@Observable
final class FocusTimer {
    enum Phase: String, CaseIterable { case focus = "Focus", rest = "Break" }

    let repo: Repo
    private(set) var phase = Phase.focus { didSet { shown = phase } }
    /// The phase on screen. You can look at the other one while the timer
    /// runs, without stopping it.
    private(set) var shown = Phase.focus
    var minutes: [Phase: Int] = [
        .focus: UserDefaults.standard.object(forKey: "focusMinutes") as? Int ?? 25,
        .rest: UserDefaults.standard.object(forKey: "restMinutes") as? Int ?? 5,
    ]
    /// The habit this session is for, if one was picked.
    var habitId: String?

    private(set) var endsAt: Date?
    private var startedAt: Date?
    private(set) var pausedRemaining: TimeInterval?
    @ObservationIgnored private var finisher: Task<Void, Never>?

    /// The phase whose time ran out, and when. Goes away after a minute, or
    /// sooner if the next one starts or it's dismissed. Nothing starts on its
    /// own, so working past the end is fine.
    private(set) var ended: (phase: Phase, at: Date)?

    /// The end has been seen in the menu bar panel, so the menu bar needn't
    /// say it any more. The timer itself still does, until `ended` goes.
    private var endSeen = false

    func markEndSeen() { if ended != nil { endSeen = true } }

    /// Whether the end makes a sound. Kept per device.
    var playsSound = UserDefaults.standard.object(forKey: "focusSound") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(playsSound, forKey: "focusSound")
            if let endsAt { scheduleNotification(at: endsAt) }
            // Lets you hear it when you turn it on.
            if playsSound { playSound() }
        }
    }

    #if os(macOS)
    /// Held while the timer runs, so macOS doesn't put the app to sleep in
    /// the background and end the session late.
    @ObservationIgnored private var activity: NSObjectProtocol?
    /// Kept here so it isn't let go while it plays. Hero, because most of the
    /// system sounds are quiet enough to miss.
    @ObservationIgnored private let sound = NSSound(named: "Hero")
    #endif

    /// Bumped when a phase finishes, for a haptic.
    private(set) var finishedCount = 0

    /// Updated every second while running, for the menu bar.
    private(set) var now = Date()
    @ObservationIgnored private var ticker: Task<Void, Never>?

    private func tick(_ on: Bool) {
        ticker?.cancel()
        now = Date()
        guard on else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.now = Date()
            }
        }
    }

    init(repo: Repo) { self.repo = repo }

    /// What the menu bar says once time's up, while that's still news.
    var endedText: String? {
        endSeen ? nil : ended.flatMap {
            FocusEnding.menuBarText(wasFocus: $0.phase == .focus, elapsed: now.timeIntervalSince($0.at))
        }
    }

    var running: Bool { endsAt != nil }
    var paused: Bool { pausedRemaining != nil }
    var total: TimeInterval { TimeInterval(minutes[phase, default: 25] * 60) }

    func remaining(at now: Date) -> TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        guard let endsAt else { return total }
        return max(0, endsAt.timeIntervalSince(now))
    }

    func start() {
        let left = remaining(at: Date())
        ended = nil
        startedAt = startedAt ?? Date()
        let end = Date().addingTimeInterval(left)
        endsAt = end
        pausedRemaining = nil
        finisher?.cancel()
        finisher = Task { [weak self] in
            try? await Task.sleep(for: .seconds(left))
            guard !Task.isCancelled else { return }
            self?.timeRanOut(at: end)
        }
        scheduleNotification(at: end)
        tick(true)
        keepAwake(true)
    }

    func pause() {
        guard running else { return }
        pausedRemaining = remaining(at: Date())
        endsAt = nil
        finisher?.cancel()
        cancelNotification()
        tick(false)
        keepAwake(false)
    }

    /// Stops the timer, or clears the note that time's up.
    func reset() {
        cancelNotification()
        clear()
    }

    private func clear() {
        finisher?.cancel()
        endsAt = nil
        startedAt = nil
        pausedRemaining = nil
        ended = nil
        tick(false)
        keepAwake(false)
    }

    /// Ends the phase now. A skipped focus session isn't recorded.
    func skip() {
        cancelNotification()
        finish(record: false)
    }

    /// The notification is left alone here: it's due at this same moment,
    /// and cancelling it could silence it.
    private func timeRanOut(at end: Date) {
        let phase = self.phase
        finish(record: true)
        // Counted from now, so if the Mac slept through the end you still see it.
        ended = (phase, Date())
        endSeen = false
        now = Date()
        #if os(macOS)
        // Just a sound and the menu bar, with no banner. If the Mac was
        // asleep when time ran out, a late sound would only be confusing.
        if playsSound && Date().timeIntervalSince(end) < 10 { playSound() }
        #endif
        ticker?.cancel()
        ticker = Task { [weak self] in
            try? await Task.sleep(for: .seconds(FocusEnding.showsFor))
            guard !Task.isCancelled else { return }
            self?.ended = nil
        }
    }

    private func playSound() {
        #if os(macOS)
        sound?.stop()
        sound?.play()
        #endif
    }

    private func keepAwake(_ on: Bool) {
        #if os(macOS)
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = on
            ? ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Focus timer")
            : nil
        #endif
    }

    /// Looks at a phase. While the timer is going, that's all it does.
    func show(_ p: Phase) {
        if running || paused {
            shown = p
        } else if p != phase {
            select(p)
        }
    }

    func select(_ p: Phase) {
        reset()
        phase = p
    }

    func setMinutes(_ value: Int, for p: Phase) {
        minutes[p] = min(180, max(1, value))
        UserDefaults.standard.set(minutes[.focus], forKey: "focusMinutes")
        UserDefaults.standard.set(minutes[.rest], forKey: "restMinutes")
    }

    private func finish(record: Bool) {
        if phase == .focus {
            if record, let startedAt {
                repo.recordFocus(start: startedAt, minutes: minutes[.focus, default: 25], habitId: habitId)
            }
            phase = .rest
        } else {
            phase = .focus
        }
        clear()
        finishedCount += 1
    }

    // MARK: Notifications, for when the iPhone or iPad app isn't open

    private func scheduleNotification(at date: Date) {
        #if !os(macOS)
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = phase == .focus ? "That's a focus session done" : "Your break's over"
        content.body = phase == .focus
            ? "Nice work. Take a short break before the next one."
            : "Ready to focus again?"
        content.sound = playsSound ? .default : nil
        // Without a sound, it waits quietly in Notification Center.
        content.interruptionLevel = playsSound ? .active : .passive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            try? await center.add(UNNotificationRequest(identifier: "focus", content: content, trigger: trigger))
        }
        #endif
    }

    private func cancelNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["focus"])
    }
}

struct FocusView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let focus = app.focus
        ScrollView {
            VStack(spacing: 28) {
                TimerPanel(focus: focus)
                TomatoRow()
                    .padding()
                    .background(.background.secondary, in: .rect(cornerRadius: 20))
                FocusStats()
            }
            .padding()
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Focus")
        .largeTitle()
        .sensoryFeedback(.success, trigger: focus.finishedCount)
    }
}

struct TimerPanel: View {
    @Bindable var focus: FocusTimer
    /// Smaller, for the Mac menu bar.
    var compact = false
    @Environment(AppModel.self) private var app

    var body: some View {
        let color: Color = focus.shown == .focus ? app.accent : .teal
        // Looking at the other phase while the timer goes on.
        let away = focus.shown != focus.phase
        let active = (focus.running || focus.paused) && !away
        let canReset = active || (focus.ended != nil && !away)
        let length = focus.minutes[focus.shown, default: 25]
        let habits = app.repo.habits.filter { !$0.isQuit }

        VStack(spacing: compact ? 16 : 24) {
            Picker("Phase", selection: Binding(get: { focus.shown }, set: { focus.show($0) })) {
                ForEach(FocusTimer.Phase.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)

            TimelineView(TickWhileRunning(running: focus.running)) { context in
                let left = away ? TimeInterval(length * 60) : focus.remaining(at: context.date)
                let progress = away ? 0 : 1 - left / focus.total
                ZStack {
                    Circle().stroke(color.opacity(0.15), lineWidth: compact ? 10 : 14)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(color, style: StrokeStyle(lineWidth: compact ? 10 : 14, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.25), value: progress)
                        // A circle for each phase, so switching doesn't
                        // animate from one's progress to the other's.
                        .id(focus.shown)
                    VStack(spacing: 4) {
                        Text(clock(left))
                            .font(.system(size: compact ? 44 : 64, weight: .light, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                        Text(hint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .minimumScaleFactor(0.7)
                            // Narrow enough to stay inside the ring, which
                            // closes in below the time.
                            .frame(maxWidth: compact ? 130 : 180)
                    }
                }
                .frame(width: compact ? 190 : 270, height: compact ? 190 : 270)
                .accessibilityElement(children: .combine)
            }

            HStack(spacing: 20) {
                Button(active ? "Reset" : "Dismiss", systemImage: active ? "arrow.counterclockwise" : "xmark",
                    action: focus.reset)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .opacity(canReset ? 1 : 0)
                    .disabled(!canReset)
                Button {
                    if away { focus.show(focus.phase) } else if focus.running { focus.pause() } else { focus.start() }
                } label: {
                    Label(away ? "Back to Timer" : focus.running ? "Pause" : focus.paused ? "Resume" : "Start",
                        systemImage: away ? "arrow.uturn.backward" : focus.running ? "pause.fill" : "play.fill")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.glassProminent)
                .tint(color)
                .controlSize(.extraLarge)
                Button("Skip", systemImage: "forward.end", action: focus.skip)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .opacity(active ? 1 : 0)
                    .disabled(!active)
            }

            VStack(spacing: 0) {
                LabeledContent("\(focus.shown.rawValue) length") {
                    HStack(spacing: 8) {
                        MinutesField(focus: focus, enabled: !active && onScreen)
                        Text("min").foregroundStyle(.secondary).fixedSize()
                        Stepper("\(focus.shown.rawValue) length", value: Binding(
                            get: { length },
                            set: { focus.setMinutes($0, for: focus.shown) }),
                            in: 1...180, step: focus.shown == .focus ? 5 : 1)
                            .labelsHidden()
                    }
                }
                .disabled(active)
                Divider().padding(.vertical, 10)
                Toggle(isOn: $focus.playsSound) {
                    Text("Play a sound when time's up").frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                // The menu bar panel keeps this space during a break, so the
                // panel doesn't change size under the pointer.
                if focus.shown == .focus || compact {
                    let showing = focus.shown == .focus
                    Divider().padding(.vertical, 10).opacity(showing ? 1 : 0)
                    let picker = Picker("Focusing on", selection: $focus.habitId) {
                        Text("Nothing in particular").tag(String?.none)
                        ForEach(habits) { Text($0.name).tag(String?.some($0.id)) }
                    }
                    .labelsHidden()
                    if compact {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Focusing on").font(.caption).foregroundStyle(.secondary)
                            picker.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .opacity(showing ? 1 : 0)
                        .disabled(!showing)
                        .accessibilityHidden(!showing)
                    } else {
                        LabeledContent("Focusing on") { picker.fixedSize() }
                    }
                }
            }
            .padding()
            .background(.background.secondary, in: .rect(cornerRadius: 20))
        }
    }

    /// The Mac keeps hidden tabs alive, so the field is turned off there;
    /// otherwise the Tab key could reach it and typing would change it.
    private var onScreen: Bool {
        #if os(macOS)
        compact || app.macTab == .focus
        #else
        true
        #endif
    }

    private var hint: String {
        if focus.shown != focus.phase {
            return focus.phase == .focus
                ? "Your focus session is \(focus.paused ? "paused" : "still going")."
                : "Your break is \(focus.paused ? "paused" : "still going")."
        }
        if focus.paused { return "Paused" }
        if !focus.running, let ended = focus.ended {
            return ended.phase == .focus
                ? "Time's up. Keep going, or take your break."
                : "Your break's over. Start when you're ready."
        }
        return focus.phase == .focus
            ? "Work on one thing until the timer ends." : "Rest before the next session."
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// The current phase's length in minutes, to type in. What's typed counts
/// straight away, since clicking Start on a Mac doesn't end editing.
private struct MinutesField: View {
    let focus: FocusTimer
    let enabled: Bool
    @State private var text = ""
    @FocusState private var editing: Bool

    private var minutes: Int { focus.minutes[focus.shown, default: 25] }

    var body: some View {
        TextField("Minutes", text: $text)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 60)
            .focused($editing)
            .disabled(!enabled)
            .help("Type a length from 1 to 180 minutes")
            .accessibilityLabel("\(focus.shown.rawValue) length in minutes")
            .onSubmit {
                showMinutes()
                editing = false
            }
            .onChange(of: text) { _, typed in
                let digits = String(typed.filter { ("0"..."9").contains($0) }.prefix(3))
                if digits != typed { text = digits }
                if enabled, let value = Int(digits), value != minutes { focus.setMinutes(value, for: focus.shown) }
            }
            // Follows the buttons and phase changes, but leaves half-typed
            // text alone (such as 200, which counts as 180).
            .onChange(of: minutes, initial: true) { _, value in
                if Int(text).map({ min(180, max(1, $0)) }) != value { showMinutes() }
            }
            .onChange(of: editing) { _, now in if !now { showMinutes() } }
            .onChange(of: enabled) { _, _ in showMinutes() }
            #if os(iOS)
            .keyboardType(.numberPad)
            .toolbar {
                // The number pad has no Return key.
                if editing {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { editing = false }
                    }
                }
            }
            #endif
    }

    private func showMinutes() { text = "\(minutes)" }
}

private struct FocusStats: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let repo = app.repo
        let today = Days.start(Date())
        let sessions = repo.focusSessions
        let todays = sessions.filter { Days.start($0.start) == today }
        let week = sessions.filter { $0.start >= Days.add(today, -6) }

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StatTile(value: "\(todays.count)", label: todays.count == 1 ? "session today" : "sessions today",
                    symbol: "timer", color: app.accent)
                StatTile(value: minutes(todays.reduce(0) { $0 + $1.minutes }), label: "focused today",
                    symbol: "sun.max", color: .orange)
                StatTile(value: minutes(week.reduce(0) { $0 + $1.minutes }), label: "in the last 7 days",
                    symbol: "calendar", color: .purple)
            }
            Text("Recent sessions").font(.headline)
            if sessions.isEmpty {
                Text("Your finished focus sessions will show up here.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(sessions.prefix(20)) { s in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(s.habitId.flatMap { repo.habit($0)?.name } ?? "Focus")
                                Text(s.start.formatted(.relative(presentation: .named)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(s.minutes) min").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                        if s.id != sessions.prefix(20).last?.id { Divider() }
                    }
                }
                .padding(.horizontal)
                .background(.background.secondary, in: .rect(cornerRadius: 20))
            }
        }
    }

    private func minutes(_ m: Int) -> String { m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m" }
}

/// Today's earned pomodoros against the daily goal: a tomato for each
/// focus session finished, and an empty slot for each one still to go.
struct TomatoRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let repo = app.repo
        let today = Days.start(Date())
        let earned = repo.focusSessions.filter { Days.start($0.start) == today }.count
        let goal = repo.prefs.focusGoal
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Today's pomodoros").font(.headline)
                Spacer()
                Menu {
                    Picker("Daily goal", selection: Binding(
                        get: { goal }, set: { repo.setPrefs(["focusGoal": .int($0)]) })
                    ) {
                        ForEach(1...12, id: \.self) { Text("\($0) a day").tag($0) }
                    }
                } label: {
                    Text(earned >= goal ? "You reached today's goal" : "\(earned) of \(goal)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(earned >= goal ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .help("Change your daily goal")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 30), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(0..<max(goal, earned), id: \.self) { i in
                    if i < earned {
                        Text("🍅").font(.system(size: 24))
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Circle()
                            .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                            .frame(width: 26, height: 26)
                            .frame(width: 30, height: 30)
                    }
                }
            }
            .animation(.spring, value: earned)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(earned) of \(goal) pomodoros today")
    }
}

/// Ticks four times a second while the timer counts down, and not at all
/// otherwise. A plain periodic schedule kept redrawing (and animating) the
/// ring even when nothing was running, which kept the Mac busy whenever the
/// Focus screen existed.
private struct TickWhileRunning: TimelineSchedule {
    let running: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        if running {
            var next = startDate
            return AnyIterator {
                defer { next += 0.25 }
                return next
            }
        }
        var done = false
        return AnyIterator {
            defer { done = true }
            return done ? nil : startDate
        }
    }
}
