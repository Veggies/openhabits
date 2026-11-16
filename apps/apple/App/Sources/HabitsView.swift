import HabitsCore
import SwiftUI

/// The main list: every habit with this week's days, so you can check
/// them all off quickly. Today is ringed, wherever it falls in the week.
struct HabitsView: View {
    @Environment(AppModel.self) private var app
    @State private var editing: EditorTarget?
    @State private var checkIns: CheckInQueue?
    @State private var confirmingDelete: Habit?

    var body: some View {
        @Bindable var app = app
        let repo = app.repo
        let habits = repo.habits
        let building = habits.filter { !$0.isQuit }
        let breaking = habits.filter(\.isQuit)
        let due = habits.filter { repo.sizeSuggestion($0) != nil }
        // This calendar week, starting on the day chosen in Settings. Days
        // still to come show faintly until they arrive.
        let weekStart = Days.startOfWeek(repo.today, firstDay: repo.weekStart)
        let days = (0..<7).map { Days.add(weekStart, $0) }

        Group {
            if habits.isEmpty {
                ContentUnavailableView {
                    Label("No habits yet", systemImage: "checklist")
                } description: {
                    Text("Start one you want to build, or one you want to break.")
                } actions: {
                    Button("New Habit") { editing = .new }
                        .buttonStyle(.glassProminent)
                }
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
                    if repo.lastWeekReviewDue || !due.isEmpty {
                        Section {
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
                    habitSection(building.isEmpty || breaking.isEmpty ? nil : "Building", building, days)
                    habitSection(breaking.isEmpty ? nil : "Breaking", breaking, days)
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
            ToolbarItem(placement: .primaryAction) {
                Button("New Habit", systemImage: "plus") { editing = .new }
            }
        }
        #endif
        .sheet(item: $editing) { target in
            HabitEditor(existing: target.habit)
        }
        .sheet(item: $checkIns) { queue in
            SizeCheckInFlow(queue: queue)
        }
        .confirmationDialog("Delete \(confirmingDelete?.name ?? "this habit")?",
            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Habit", role: .destructive) {
                if let h = confirmingDelete { repo.deleteHabit(h.id) }
            }
        } message: {
            Text("This removes it and its check-ins from all your devices.")
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
                ForEach(list) { habit in
                    habitLink(habit, days)
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
        let missed = repo.atomicHabits && repo.missedLastTime(habit)
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
        let missed = repo.atomicHabits && repo.missedLastTime(habit)
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
        let scheduled = habit.isScheduled(day)
        let upcoming = day > app.repo.today
        let size: CGFloat = isToday ? 30 : 24
        Button {
            // A later day takes the tap without doing anything, so it
            // doesn't fall through and open the habit.
            guard !upcoming else { return }
            withAnimation(.snappy(duration: 0.25)) { app.repo.toggle(habit.id, day) }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(
                        done || isToday ? habit.tint : Color.secondary.opacity(scheduled && !upcoming ? 0.35 : 0.12),
                        lineWidth: isToday ? 2.5 : 1.5)
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
        .sensoryFeedback(.success, trigger: done) { old, new in isToday && !old && new }
        .accessibilityLabel(isToday ? "Today" : day.formatted(.dateTime.weekday(.wide)))
        .accessibilityValue(upcoming ? "Upcoming" : done ? (habit.isQuit ? "Stayed clear" : "Done") : "Not done")
        .help(isToday ? (habit.isQuit ? "Stayed clear today" : "Done today") : day.formatted(.dateTime.weekday(.wide)))
    }
}
