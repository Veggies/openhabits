import HabitsCore
import SwiftUI

/// One habit: how it's going, a month of check-ins you can change, and its
/// plan.
struct HabitDetailView: View {
    let habitId: String
    /// Set when the page is shown in the Mac's preview panel: closes it.
    var close: (() -> Void)? = nil
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var month = Days.start(Date())
    @State private var editing = false
    @State private var confirmingDelete = false
    @State private var checkIns: CheckInQueue?

    var body: some View {
        let repo = app.repo
        if let habit = repo.habit(habitId), !habit.deleted {
            List {
                Section {
                    header(habit)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                if let suggestion = repo.sizeSuggestion(habit) {
                    Section {
                        Button {
                            checkIns = CheckInQueue(ids: [habit.id])
                        } label: {
                            Banner(symbol: suggestion == .grow ? "arrow.up.right" : "arrow.down.right",
                                color: app.accent,
                                title: suggestion == .grow ? "Is it starting to feel too easy?" : "Make it a little smaller?",
                                message: suggestion == .grow
                                    ? "You've done it on most days lately. Have a quick look at its size."
                                    : "It's been hard to fit in lately. A smaller version might help.")
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section {
                    MonthCalendar(habit: habit, month: $month)
                }
                planSection(habit)
            }
            .groupedList()
            .navigationTitle(habit.name)
            .inlineTitle()
            .toolbar {
                // As a full page (iPhone), the actions go in the navigation bar.
                if close == nil {
                    ToolbarItem(placement: .primaryAction) { moreMenu(habit) }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit") { editing = true }
                    }
                }
            }
            // As a card (Mac), they sit on the card itself.
            .overlay(alignment: .topTrailing) {
                if let close {
                    HStack(spacing: 10) {
                        moreMenu(habit)
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                        Button("Edit") { editing = true }
                            .buttonStyle(.glassProminent)
                        Button("Close", systemImage: "xmark", action: close)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .help("Close (Esc)")
                    }
                    .controlSize(.large)
                    .padding(16)
                }
            }
            .sheet(isPresented: $editing) { HabitEditor(existing: habit) }
            .sheet(item: $checkIns) { SizeCheckInFlow(queue: $0) }
            .confirmationDialog("Delete \(habit.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete Habit", role: .destructive) {
                    repo.deleteHabit(habit.id)
                    leave()
                }
            } message: {
                Text("This removes it from all your devices.")
            }
        } else {
            ContentUnavailableView("This habit was deleted", systemImage: "trash")
        }
    }

    private func moreMenu(_ habit: Habit) -> some View {
        Menu {
            Button("Archive", systemImage: "archivebox") {
                app.repo.updateHabit(habit.id, ["archived": true])
                leave()
            }
            Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
        } label: {
            Label("More", systemImage: "ellipsis").labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
    }

    /// Back to the list: closes the card, or pops the page.
    private func leave() {
        if let close { close() } else { dismiss() }
    }

    private func header(_ habit: Habit) -> some View {
        let repo = app.repo
        let strength = repo.strength(habit)
        let count = habit.isQuit ? repo.daysClean(habit) : repo.streak(habit)
        return VStack(spacing: 14) {
            HabitIcon(icon: habit.icon, color: habit.color, size: 72)
            #if os(macOS)
            Text(habit.name).font(.largeTitle.bold())
            #endif
            if !habit.plan.identity.isEmpty {
                Text("I am \(habit.plan.identity)")
                    .font(.subheadline)
                    .italic()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                StatTile(value: "\(count)",
                    label: habit.isQuit ? (count == 1 ? "day clean" : "days clean") : (count == 1 ? "day streak" : "day streak"),
                    symbol: habit.isQuit ? "shield.fill" : "flame.fill",
                    color: habit.isQuit ? .green : .orange)
                StatTile(value: strength.level.label,
                    label: strength.level == .justStarted ? "too soon to say" : daysLabel(habit, strength.done, strength.scheduled),
                    symbol: "chart.line.uptrend.xyaxis",
                    color: strength.level.color)
                StatTile(value: "\(repo.votes(habit.id))",
                    label: !habit.plan.identity.isEmpty ? "votes for who you're becoming" : "check-ins",
                    symbol: "checkmark",
                    color: habit.tint)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func planSection(_ habit: Habit) -> some View {
        let plan = habit.plan
        let rows: [(String, String)] = habit.isQuit
            ? [
                ("Remove the cue", plan.invisible), ("Reframe it", plan.unattractive),
                ("Add friction", plan.difficult), ("Accountability", plan.unsatisfying),
                ("Habit contract", plan.contract),
            ]
            : [
                ("Your version for now", plan.twoMinute),
                ("Grown from", versionHistory(plan) ?? ""),
                ("After I…", plan.stackAfter),
                ("When", plan.time.isEmpty ? "" : "\(timeLabel(plan.time)), for \(durationLabel(habit.duration))"),
                ("Where", plan.location),
                ("Pair it with", plan.bundle),
                ("Reward", plan.reward),
                ("Days", habit.weekdays.count == 7 ? "Every day"
                    : Days.order(startingOn: app.repo.weekStart).filter(habit.weekdays.contains).map(weekdayShort).joined(separator: ", ")),
            ]
        let filled = rows.filter { !$0.1.isEmpty }
        if !filled.isEmpty {
            Section(habit.isQuit ? "Your plan to break it" : "Your plan") {
                ForEach(filled, id: \.0) { row in
                    LabeledContent(row.0) {
                        Text(row.1).multilineTextAlignment(.trailing)
                    }
                }
                if plan.sizeSettled && !plan.twoMinute.isEmpty {
                    Button("Start Checking In on the Size Again") { app.repo.settleSize(habit, settled: false) }
                }
            }
        }
    }
}

struct StatTile: View {
    let value: String
    let label: String
    let symbol: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }
}

/// A month of check-ins. Tap any day up to today to change it, or long-press
/// a day (right-click on a Mac) to give the habit that day off. Months ahead
/// are there for planning time off.
struct MonthCalendar: View {
    let habit: Habit
    @Binding var month: Date
    @Environment(AppModel.self) private var app

    var body: some View {
        let repo = app.repo
        let cal = Days.calendar
        let first = cal.date(from: cal.dateComponents([.year, .month], from: month)) ?? month
        let length = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        let order = Days.order(startingOn: repo.weekStart)
        let lead = order.firstIndex(of: Days.weekday(first)) ?? 0
        let cells: [Date?] = Array(repeating: nil, count: lead) + (0..<length).map { Days.add(first, $0) }
        let today = repo.today

        VStack(spacing: 10) {
            HStack {
                Text(first.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
                Spacer()
                Button("Previous Month", systemImage: "chevron.left") { month = Days.addMonths(first, -1) }
                    .labelStyle(.iconOnly)
                Button("Next Month", systemImage: "chevron.right") { month = Days.addMonths(first, 1) }
                    .labelStyle(.iconOnly)
                    .disabled(Days.addMonths(first, 1) > Days.addMonths(today, 12))
            }
            .buttonStyle(.borderless)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                ForEach(order, id: \.self) { d in
                    Text(weekdayLetter(d))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day, today: today)
                    } else {
                        Color.clear.frame(height: 36)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        #if os(macOS)
        // The list row's menu wins over one on a single day, so the whole
        // calendar has one, for the day under the pointer.
        .contextMenu {
            if let pointed = app.pointedDay, pointed.habitId == habit.id {
                DayOffMenu(habit: habit, day: pointed.day, named: true)
            }
        }
        #endif
    }

    private func dayCell(_ day: Date, today: Date) -> some View {
        let repo = app.repo
        let done = repo.isDone(habit.id, day)
        let off = repo.isOff(habit.id, day)
        let open = day <= today && day >= habit.startDay
        let scheduled = habit.isScheduled(day)
        return Button {
            // Later days can't be ticked yet, but can be given the day off
            // from the menu.
            guard open, scheduled || done else { return }
            withAnimation(.snappy(duration: 0.2)) { repo.toggle(habit.id, day) }
        } label: {
            Text("\(Days.calendar.component(.day, from: day))")
                .font(.callout.weight(day == today ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(done ? AnyShapeStyle(.white)
                    : open && scheduled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 36, height: 36)
                .background {
                    if done {
                        Circle().fill(habit.tint)
                    } else if off {
                        Circle().strokeBorder(habit.tint.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    } else if day == today {
                        Circle().strokeBorder(habit.tint, lineWidth: 2)
                    }
                }
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderless)
        .disabled(day < habit.startDay)
        #if os(macOS)
        .onHover { inside in
            if inside {
                app.pointedDay = (habit.id, day)
            } else if app.pointedDay?.habitId == habit.id && app.pointedDay?.day == day {
                app.pointedDay = nil
            }
        }
        #else
        .contextMenu { DayOffMenu(habit: habit, day: day) }
        #endif
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
        .accessibilityValue(off ? "Day off" : done ? "Done" : "Not done")
    }
}

// MARK: - Size check-ins

/// Habits waiting for a size check-in, asked about one after another.
struct CheckInQueue: Identifiable {
    let id = UUID()
    let ids: [String]
}

/// Steps through each habit's check-in. Closing one without choosing stops
/// there; the rest wait until next time.
struct SizeCheckInFlow: View {
    let queue: CheckInQueue
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    var body: some View {
        let repo = app.repo
        let remaining = queue.ids.enumerated().filter { _, id in
            repo.habit(id).flatMap { repo.sizeSuggestion($0) } != nil
        }
        NavigationStack {
            if index < queue.ids.count, let habit = repo.habit(queue.ids[index]),
                let suggestion = repo.sizeSuggestion(habit)
            {
                SizeCheckIn(habit: habit, suggestion: suggestion,
                    step: queue.ids.count > 1 ? "\(index + 1) of \(queue.ids.count)" : nil
                ) {
                    advance()
                }
                .id(habit.id)
                .transition(.push(from: .trailing))
            } else {
                Color.clear.onAppear { advance() }
            }
        }
        .animation(.default, value: index)
        .onAppear {
            if remaining.isEmpty { dismiss() }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    private func advance() {
        let repo = app.repo
        var next = index + 1
        while next < queue.ids.count,
            repo.habit(queue.ids[next]).flatMap({ repo.sizeSuggestion($0) }) == nil
        {
            next += 1
        }
        if next >= queue.ids.count { dismiss() } else { index = next }
    }
}

/// The two-weekly check-in (the Goldilocks rule): grow it, shrink it, keep
/// it as it is, or say the size feels right.
struct SizeCheckIn: View {
    let habit: Habit
    let suggestion: SizeSuggestion
    let step: String?
    let onDone: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var version = ""

    var body: some View {
        let repo = app.repo
        let grow = suggestion == .grow
        let r = repo.record(habit, end: repo.today, days: 14)
        Form {
            Section {
                HStack(spacing: 14) {
                    HabitIcon(icon: habit.icon, color: habit.color, size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(habit.name).font(.title2.bold())
                        Text(grow ? "Is it starting to feel too easy?" : "Make it a little smaller?")
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                Text(grow
                    ? "Over the last two weeks, you did this on \(r.done) of the \(r.scheduled) days it was scheduled, so it's sticking. Nice going.\n\nIf it's starting to feel too easy, you could make it a little bigger. If it still takes some effort, keeping it as it is works just as well."
                    : "Over the last two weeks, you did this on \(r.done) of the \(r.scheduled) days it was scheduled. That's completely normal. A smaller version that you actually do beats a bigger one you skip.")
                LabeledContent("Your version for now", value: habit.plan.twoMinute)
            }
            Section {
                HintField("Your new version", text: $version, axis: .vertical)
                    .onSubmit(change)
            } header: {
                Text("Your new version")
            } footer: {
                Text(grow ? "Just a little bigger. For example, one page could become five."
                    : "Something easy enough to do even on a busy day.")
            }
            Section {
                Button(action: change) {
                    Text(grow ? "Make It Bigger" : "Make It Smaller").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                Button {
                    repo.keepSize(habit)
                    onDone()
                } label: {
                    Text("Keep It as It Is").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
            } footer: {
                Button("This feels right, stop asking") {
                    repo.settleSize(habit)
                    onDone()
                }
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(step ?? "Check-in")
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Not Now") { dismiss() }
            }
        }
        .onAppear { version = habit.plan.twoMinute }
    }

    private func change() {
        let next = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if next.isEmpty || next == habit.plan.twoMinute {
            app.repo.keepSize(habit)
        } else {
            app.repo.resize(habit, to: next)
        }
        onDone()
    }
}
