import HabitsCore
import SwiftUI

/// The main list: every habit with this week's days, so you can check
/// them all off quickly. Today is ringed, wherever it falls in the week.
struct HabitsView: View {
    @Environment(AppModel.self) private var app
    @State private var editing: EditorTarget?
    @State private var checkIns: CheckInQueue?
    @State private var confirmingDelete: Habit?
    @State private var editingTask: TaskDraft?

    var body: some View {
        @Bindable var app = app
        let repo = app.repo
        let habits = repo.habits
        // Habits due today come first. The rest wait underneath, so you can
        // still see their week.
        let building = habits.filter { !$0.isQuit && $0.isScheduled(repo.today) }
        let breaking = habits.filter(\.isQuit)
        let notToday = habits.filter { !$0.isQuit && !$0.isScheduled(repo.today) }
        let due = habits.filter { repo.sizeSuggestion($0) != nil }
        let ready = repo.rewardsReady
        let tasks = repo.tasksForToday
        // This calendar week, starting on the day chosen in Settings. Days
        // still to come show faintly until they arrive.
        let weekStart = Days.startOfWeek(repo.today, firstDay: repo.weekStart)
        let days = (0..<7).map { Days.add(weekStart, $0) }

        Group {
            // Today's tasks still show when there are no habits yet.
            if habits.isEmpty && tasks.isEmpty {
                ContentUnavailableView {
                    Label("No habits yet", systemImage: "checklist")
                } description: {
                    Text("Start one you want to build, or one you want to break.")
                } actions: {
                    Button("New Habit") { editing = .new }
                        .buttonStyle(.glassProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    #if os(macOS)
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Today").font(.largeTitle.bold())
                            Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("New Habit", systemImage: "plus") { editing = .new }
                            .buttonStyle(.glassProminent)
                            .controlSize(.large)
                            .help("New Habit (⌘N)")
                    }
                    .padding(.top, 6)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    #endif
                    if repo.lastWeekReviewDue || !due.isEmpty || !ready.isEmpty {
                        Section {
                            if !ready.isEmpty {
                                Button {
                                    app.tab = .focus
                                    #if os(macOS)
                                    app.macTab = .focus
                                    #endif
                                } label: {
                                    Banner(symbol: "gift", color: .red,
                                        title: "You've earned a reward",
                                        message: rewardsReadyMessage(ready, left: repo.tomatoesToSpend))
                                }
                            }
                            if repo.lastWeekReviewDue {
                                Button {
                                    app.tab = .reflect
                                    #if os(macOS)
                                    app.macTab = .reflect
                                    #endif
                                } label: {
                                    Banner(symbol: "text.book.closed", color: .purple,
                                        title: "Time for your weekly review",
                                        message: "Take a minute to look back on last week and see how your habits went.")
                                }
                            }
                            if !due.isEmpty {
                                Button {
                                    checkIns = CheckInQueue(ids: due.map(\.id))
                                } label: {
                                    Banner(symbol: "slider.horizontal.3", color: app.accent,
                                        title: "Time for a check-in",
                                        message: "See whether \(names(due)) still \(due.count == 1 ? "feels" : "feel") like the right size.")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    habitSection(breaking.isEmpty && notToday.isEmpty ? nil : "Building", building, days)
                    habitSection(building.isEmpty && notToday.isEmpty ? nil : "Breaking", breaking, days)
                    taskSection(tasks)
                    habitSection("Not Today", notToday, days)
                }
                .groupedList()
                .animation(.default, value: habits.map(\.id))
            }
        }
        #if os(macOS)
        .navigationTitle("Today")
        #else
        .navigationTitle("Habits")
        #endif
        .largeTitle()
        .navigationDestination(for: String.self) { HabitDetailView(habitId: $0) }
        #if os(iOS)
        .toolbar {
            if isPhone {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New Habit", systemImage: "plus") { editing = .new }
            }
        }
        #endif
        .sheet(item: $editingTask) { TaskEditor(draft: $0) }
        .sheet(item: $editing) { target in
            HabitEditor(existing: target.habit)
        }
        .sheet(item: $checkIns) { queue in
            SizeCheckInFlow(queue: queue)
        }
        #if DEBUG
        // -openScreen checkIn | editor: opens a sheet straight away, for
        // screenshots (see SampleData.swift).
        .onAppear {
            switch UserDefaults.standard.string(forKey: "openScreen") {
            case "checkIn" where !due.isEmpty: checkIns = CheckInQueue(ids: due.map(\.id))
            case "editor", "editorPlan": editing = habits.first.map { .edit($0) }
            default: break
            }
        }
        #endif
        .confirmationDialog("Delete \(confirmingDelete?.name ?? "this habit")?",
            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Habit", role: .destructive) {
                if let h = confirmingDelete { repo.deleteHabit(h.id) }
            }
        } message: {
            Text("This removes it from all your devices.")
        }
        #if os(iOS)
        .onChange(of: app.newHabitRequested) { _, requested in
            if requested {
                editing = .new
                app.newHabitRequested = false
            }
        }
        #endif
    }

    /// On the Mac, a plain row (a link would reserve room for an arrow and
    /// push the circles out of line with the day labels); clicking the
    /// habit's name opens its page.
    @ViewBuilder
    private func habitLink(_ habit: Habit, _ days: [Date]) -> some View {
        #if os(macOS)
        HabitRow(habit: habit, days: days) {
            withAnimation(.smooth(duration: 0.32)) { app.previewHabit = habit.id }
        }

        #else
        NavigationLink(value: habit.id) {
            HabitRow(habit: habit, days: days)
        }
        #endif
    }

    /// Tasks due today or overdue, and the ones you've ticked off today, so
    /// the whole day is in one place.
    @ViewBuilder
    private func taskSection(_ tasks: [TaskItem]) -> some View {
        if !tasks.isEmpty {
            Section {
                #if os(macOS)
                Text("Tasks").font(.headline).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                #endif
                ForEach(tasks) { TaskRow(task: $0, editing: $editingTask, inToday: true) }
            } header: {
                #if os(iOS)
                Text("Tasks")
                #endif
            }
        }
    }

    @ViewBuilder
    private func habitSection(_ title: String?, _ list: [Habit], _ days: [Date]) -> some View {
        if !list.isEmpty {
            Section {
                #if os(macOS)
                // Laid out exactly like a habit row, so the labels sit right
                // above the circles.
                HStack(spacing: 12) {
                    HStack {
                        Text(title ?? "").font(.headline).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                    }
                    .frame(minWidth: 220)
                    DayLabelRow(days: days)
                }
                .listRowSeparator(.hidden)
                #endif
                ForEach(Array(list.enumerated()), id: \.element.id) { i, habit in
                    habitLink(habit, days)
                    // Every other habit gets the same faint band as Progress.
                    .listRowBackground(i.isMultiple(of: 2) ? StripeBackground() : nil)
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = habit }
                        Button("Archive", systemImage: "archivebox") {
                            app.repo.updateHabit(habit.id, ["archived": true])
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button("Edit", systemImage: "pencil") { editing = .edit(habit) }
                            .tint(app.accent)
                        if !habit.isQuit {
                            Button("Focus", systemImage: "timer") { app.focus(on: habit) }
                                .tint(.red)
                        }
                    }
                    .contextMenu {
                        RowDayOffMenu(habit: habit, days: days)
                        if !habit.isQuit {
                            Button("Focus on This", systemImage: "timer") { app.focus(on: habit) }
                        }
                        Button("Edit", systemImage: "pencil") { editing = .edit(habit) }
                        Button("Archive", systemImage: "archivebox") {
                            app.repo.updateHabit(habit.id, ["archived": true])
                        }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = habit }
                    }
                }
            } header: {
                #if os(iOS)
                // Each row labels its own days on iPhone, so the header is
                // just the group's name.
                if let title { Text(title) }
                #endif
            }
        }
    }
}

/// "You can enjoy an episode of a show. You have 4 tomatoes to spend today."
func rewardsReadyMessage(_ ready: [Reward], left: Int) -> String {
    let shown = ready.prefix(3).map(\.name)
    let list = shown.count <= 1 ? shown.joined()
        : shown.dropLast().joined(separator: ", ") + " or " + shown.last!
    let more = ready.count > 3 ? ", or something else" : ""
    return "You can enjoy \(list)\(more). You have \(left) tomato\(left == 1 ? "" : "es") to spend today."
}

/// "Read", "Read and Walk", "Read, Walk and Journal".
func names(_ habits: [Habit]) -> String {
    let all = habits.map(\.name)
    guard all.count > 1 else { return all.first ?? "" }
    return all.dropLast().joined(separator: ", ") + " and " + all.last!
}

enum EditorTarget: Identifiable {
    case new
    case edit(Habit)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let h): h.id
        }
    }

    var habit: Habit? {
        if case .edit(let h) = self { return h }
        return nil
    }
}

/// A tappable note at the top of the list.
struct Banner: View {
    let symbol: String
    let color: Color
    let title: String
    let message: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}

/// The days, labelled once above a section's circles.
struct DayLabelRow: View {
    let days: [Date]
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                let isToday = day == app.repo.today
                Text(isToday ? "Today" : dayLabel(Days.weekday(day)))
                    .font(.caption2.weight(isToday ? .bold : .medium))
                    .foregroundStyle(isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: daySlot)
                    .fixedSize()
            }
        }
    }
}

/// Width of each day's circle, so the labels line up above them.
let daySlot: CGFloat = 36

/// The section header: its name, and the days labelled once above the
/// circles.
struct DayLabels: View {
    let title: String?
    let days: [Date]
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            Text(title ?? "")
                .fixedSize()
            Spacer(minLength: 8)
            ForEach(days, id: \.self) { day in
                let isToday = day == app.repo.today
                Text(isToday ? "Today" : dayLabel(Days.weekday(day)))
                    .font(.caption2.weight(isToday ? .bold : .medium))
                    .foregroundStyle(isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: daySlot)
                    .fixedSize()
            }
        }
        .padding(.trailing, rowTrailing)
    }
}

/// Room the list leaves after the circles: the disclosure arrow on iPhone,
/// the row's inset on the Mac.
#if os(iOS)
let rowTrailing: CGFloat = 20
#else
let rowTrailing: CGFloat = 10
#endif

/// "M" on iPhone, "Mon" on the Mac, which has room.
private func dayLabel(_ weekday: Int) -> String {
    #if os(macOS)
    weekdayShort(weekday)
    #else
    weekdayLetter(weekday)
    #endif
}

struct HabitRow: View {
    let habit: Habit
    let days: [Date]
    /// Opens the habit's page when its name is clicked (Mac).
    var open: (() -> Void)? = nil
    @Environment(AppModel.self) private var app

    var body: some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            phoneRow
        } else {
            wideRow
        }
        #else
        wideRow
        #endif
    }

    /// iPhone: the name with its time beside it, the plan underneath
    /// (wrapping rather than cut off), and the week spread across the row
    /// with each day labelled under its circle.
    private var phoneRow: some View {
        let repo = app.repo
        let missed = repo.missedLastTime(habit)
        let detail = missed
            ? (habit.isQuit ? "Yesterday wasn't a clear day" : "You missed this last time")
            : detailLine(habit, repo: repo, includeTime: false)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                HabitIcon(icon: habit.icon, color: habit.color, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(habit.name)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                            .layoutPriority(1)
                        if !habit.plan.time.isEmpty {
                            Label(timeLabel(habit.plan.time), systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .labelStyle(.titleAndIcon)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(missed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                StreakBadge(habit: habit)
            }
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    DayCircle(habit: habit, day: day, isToday: day == app.repo.today, labelled: true)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private var wideRow: some View {
        let repo = app.repo
        let missed = repo.missedLastTime(habit)
        let detail = missed
            ? (habit.isQuit ? "Yesterday wasn't a clear day" : "You missed this last time")
            : detailLine(habit, repo: repo)

        let name = HStack(spacing: 12) {
            HabitIcon(icon: habit.icon, color: habit.color, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(habit.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(missed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            StreakBadge(habit: habit)
        }
        .contentShape(.rect)
        .onTapGesture { open?() }

        let week = HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                DayCircle(habit: habit, day: day, isToday: day == app.repo.today)
            }
        }

        // Everything on one line when there's room; otherwise the week sits
        // underneath, still lined up on the right.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                name.frame(minWidth: 220)
                week
            }
            VStack(alignment: .trailing, spacing: 6) {
                name
                week
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

struct StreakBadge: View {
    let habit: Habit
    @Environment(AppModel.self) private var app

    var body: some View {
        let count = habit.isQuit ? app.repo.daysClean(habit) : app.repo.streak(habit)
        HStack(spacing: 2) {
            Image(systemName: habit.isQuit ? "shield.fill" : "flame.fill")
                .foregroundStyle(count == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(habit.isQuit ? .green : .orange))
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.subheadline.weight(.semibold))
        .accessibilityLabel(habit.isQuit
            ? "\(count) day\(count == 1 ? "" : "s") clean"
            : "A streak of \(count) day\(count == 1 ? "" : "s")")
    }
}

/// One day's check-in. Today's circle is a little bigger and ringed in the
/// habit's colour.
struct DayCircle: View {
    let habit: Habit
    let day: Date
    let isToday: Bool
    /// Shows the day's letter under the circle (iPhone).
    var labelled = false
    @Environment(AppModel.self) private var app

    var body: some View {
        let done = app.repo.isDone(habit.id, day)
        let off = app.repo.isOff(habit.id, day)
        let scheduled = habit.isScheduled(day)
        let upcoming = day > app.repo.today
        // Today is bigger and ringed, but only on a habit that's due today.
        let due = isToday && scheduled
        // A day that isn't one of the habit's days is a small dot rather
        // than a circle, unless it was ticked before.
        let dot = !scheduled && !done
        let size: CGFloat = due ? 30 : 24
        Button {
            // A later day, or one the habit isn't scheduled on, takes the
            // tap without doing anything, so it doesn't fall through and
            // open the habit. A tick already there can still be undone.
            guard !upcoming, scheduled || done else { return }
            withAnimation(.snappy(duration: 0.25)) { app.repo.toggle(habit.id, day) }
        } label: {
            ZStack {
                if dot {
                    Circle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 5, height: 5)
                } else if off {
                    // Dashed: the habit has the day off, so it isn't missed.
                    Circle()
                        .strokeBorder(habit.tint.opacity(0.7),
                            style: StrokeStyle(lineWidth: due ? 2.5 : 1.5, dash: [3, 3]))
                } else {
                    Circle()
                        .strokeBorder(
                            done || due ? habit.tint : Color.secondary.opacity(scheduled && !upcoming ? 0.35 : 0.12),
                            lineWidth: due ? 2.5 : 1.5)
                }
                if done {
                    Circle().fill(habit.tint)
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.45, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: size, height: size)
            .frame(width: daySlot, height: labelled ? 32 : 36)
            .overlay(alignment: .bottom) {
                if labelled {
                    Text(weekdayShort(Days.weekday(day)))
                        .font(.caption2.weight(isToday ? .bold : .medium))
                        .foregroundStyle(isToday ? AnyShapeStyle(.tint)
                            : upcoming ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                        .offset(y: 15)
                }
            }
            .padding(.bottom, labelled ? 14 : 0)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        #if os(macOS)
        .onHover { inside in pointing(at: day, inside) }
        #else
        .contextMenu { DayOffMenu(habit: habit, day: day) }
        #endif
        .sensoryFeedback(.success, trigger: done) { old, new in isToday && !old && new }
        .accessibilityLabel(isToday ? "Today" : day.formatted(.dateTime.weekday(.wide)))
        .accessibilityValue(off ? "Day off" : upcoming ? "Upcoming" : done ? (habit.isQuit ? "Stayed clear" : "Done")
            : scheduled ? "Not done" : "Not scheduled")
        .help(off ? "A day off, so it won't count as missed"
            : !scheduled && !done ? "Not one of this habit's days"
            : isToday ? (habit.isQuit ? "Stayed clear today" : "Done today") : day.formatted(.dateTime.weekday(.wide)))
    }
}

#if os(macOS)
extension DayCircle {
    /// Remembers the day under the pointer, for the row's right-click menu.
    fileprivate func pointing(at day: Date, _ inside: Bool) {
        if inside {
            app.pointedDay = (habit.id, day)
        } else if app.pointedDay?.habitId == habit.id && app.pointedDay?.day == day {
            app.pointedDay = nil
        }
    }
}
#endif

/// Whether a habit can be given `day` off, or have it back: only days it's
/// scheduled, from when it started, and not days already done. Habits
/// you're breaking don't take days off.
@MainActor func canTakeOff(_ habit: Habit, _ day: Date, _ repo: Repo) -> Bool {
    !habit.isQuit && habit.isScheduled(day) && day >= habit.startDay
        && (repo.isOff(habit.id, day) || !repo.isDone(habit.id, day))
}

/// Giving a habit a day off, or taking it back. `named` puts the day in the
/// words ("Take Wednesday Off"), for menus that aren't on the day itself.
struct DayOffMenu: View {
    let habit: Habit
    let day: Date
    var named = false
    @Environment(AppModel.self) private var app

    var body: some View {
        let repo = app.repo
        if canTakeOff(habit, day, repo) {
            let name = named ? dayName(day, today: repo.today) : "the Day"
            if repo.isOff(habit.id, day) {
                Button("Undo \(named ? name + "\u{2019}s" : "the") Day Off", systemImage: "arrow.uturn.backward") {
                    withAnimation(.snappy(duration: 0.25)) { repo.setOff(habit.id, day, false) }
                }
            } else {
                Button("Take \(name) Off", systemImage: "moon.zzz") {
                    withAnimation(.snappy(duration: 0.25)) { repo.setOff(habit.id, day, true) }
                }
            }
        }
    }
}

/// What a habit row's own menu offers for days off: on a Mac, the day under
/// the pointer first, then a Day Off menu with every day of the week shown
/// that can be taken off.
struct RowDayOffMenu: View {
    let habit: Habit
    let days: [Date]
    @Environment(AppModel.self) private var app

    var body: some View {
        let repo = app.repo
        let open = days.filter { canTakeOff(habit, $0, repo) }
        if !open.isEmpty {
            #if os(macOS)
            if let pointed = app.pointedDay, pointed.habitId == habit.id, open.contains(pointed.day) {
                DayOffMenu(habit: habit, day: pointed.day, named: true)
            }
            #endif
            Menu("Day Off", systemImage: "moon.zzz") {
                ForEach(open, id: \.self) { day in
                    DayOffMenu(habit: habit, day: day, named: true)
                }
            }
            Divider()
        }
    }
}

/// "Today", "Tomorrow", the day's name within a week ("Wednesday"), or
/// the date further away ("Dec 24").
func dayName(_ day: Date, today: Date) -> String {
    let away = Days.between(today, day)
    switch away {
    case 0: return "Today"
    case 1: return "Tomorrow"
    case -1: return "Yesterday"
    case -6...6: return day.formatted(.dateTime.weekday(.wide))
    default: return day.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// The faint band behind every other habit row, matching the Progress grid:
/// on iPhone and iPad a tint over the list's card, on the Mac a rounded band.
struct StripeBackground: View {
    var body: some View {
        #if os(iOS)
        ZStack {
            Color(uiColor: .secondarySystemGroupedBackground)
            Color.primary.opacity(0.05)
        }
        #else
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.05))
            .padding(.horizontal, 10)
        #endif
    }
}
