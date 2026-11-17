import HabitsCore
import SwiftUI

/// How much history the grid shows.
enum ProgressRange: String, CaseIterable, Identifiable {
    case all = "Since You Started"
    case month = "1 Month"
    case quarter = "3 Months"
    case half = "6 Months"
    case year = "1 Year"
    case custom = "Custom Dates"

    var id: Self { self }

    var days: Int {
        switch self {
        case .month: 30
        case .quarter: 91
        case .half: 182
        case .year: 365
        default: 0
        }
    }
}

/// One row per habit, one column per week. Each square holds the number of
/// days you did the habit that week (or stayed clear, for habits you're
/// breaking), and is solid when you did it every day it was due.
struct ProgressScreen: View {
    @Environment(AppModel.self) private var app
    @State private var range = ProgressRange.all
    @State private var customFrom = Days.add(Days.start(Date()), -30)
    @State private var customTo = Days.start(Date())
    @State private var choosingDates = false
    /// Habits switched off. Tracking the hidden ones means new habits show
    /// up without extra steps.
    @State private var hidden: Set<String> = []

    var body: some View {
        let repo = app.repo
        let habits = repo.habits
        let today = repo.today
        let started = habits.map(\.startDay).min() ?? today
        let (from, to): (Date, Date) =
            switch range {
            case .all: (started, today)
            case .custom: (customFrom, customTo)
            default: (Days.add(today, -range.days), today)
            }
        let weeks = stride(from: 0, to: 1000, by: 1).lazy
            .map { Days.add(Days.startOfWeek(from, firstDay: repo.weekStart), $0 * 7) }
            .prefix { $0 <= to }
        let shown = habits.filter { !hidden.contains($0.id) }

        Group {
            if habits.isEmpty {
                // Centred in the whole screen, with a way to get started,
                // rather than tucked under the explanation.
                ContentUnavailableView {
                    Label("Nothing to show yet", systemImage: "square.grid.3x3")
                } description: {
                    Text("Once you've started a habit, you'll see how each week went here.")
                } actions: {
                    Button("New Habit") {
                        app.tab = .habits
                        #if os(macOS)
                        app.macTab = .today
                        #endif
                        app.newHabitRequested = true
                    }
                    .buttonStyle(.glassProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                grid(habits: habits, shown: shown, weeks: Array(weeks), today: today)
            }
        }
        .navigationTitle("Progress")
        .largeTitle()
        .sheet(isPresented: $choosingDates) {
            NavigationStack {
                Form {
                    DatePicker("From", selection: $customFrom, in: ...customTo, displayedComponents: .date)
                    DatePicker("To", selection: $customTo, in: customFrom...Days.start(Date()), displayedComponents: .date)
                }
                .formStyle(.grouped)
                .navigationTitle("Choose Dates")
                .inlineTitle()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            range = .custom
                            choosingDates = false
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    /// The page once there are habits: filters, the key, and the grid.
    private func grid(habits: [Habit], shown: [Habit], weeks: [Date], today: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                #if os(macOS)
                HStack(spacing: 12) {
                    Text("Progress").font(.largeTitle.bold())
                    Spacer()
                    datePicker
                    if habits.count > 1 { habitFilter(habits) }
                }
                #else
                // Two separate, labelled buttons, so it's clear each does
                // its own thing.
                HStack(spacing: 10) {
                    datePicker
                    if habits.count > 1 { habitFilter(habits) }
                    Spacer(minLength: 0)
                }
                #endif
                Text("Here's how each habit has gone, week by week. The number in each square is how many days you did it that week. For habits you're trying to break, it's how many days you went without it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if shown.isEmpty {
                    ContentUnavailableView("No habits chosen", systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Choose which habits to show with the filter button."))
                } else {
                    Legend()
                    WeekGrid(habits: shown, weeks: weeks, today: today)
                }
            }
            .padding()
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var rangeTitle: String {
        range == .custom ? "\(shortDate(customFrom)) – \(shortDate(customTo))" : range.rawValue
    }

    /// Which weeks to show, as a labelled menu button.
    private var datePicker: some View {
        Menu {
            Picker("Dates", selection: Binding(get: { range }, set: { pick($0) })) {
                ForEach(ProgressRange.allCases) { r in
                    Text(r.rawValue).tag(r)
                }
            }
        } label: {
            Label {
                HStack(spacing: 4) {
                    Text(rangeTitle)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                }
            } icon: {
                Image(systemName: "calendar")
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func habitFilter(_ habits: [Habit]) -> some View {
        Menu {
            ForEach(habits) { h in
                Toggle(h.name, isOn: Binding(
                    get: { !hidden.contains(h.id) },
                    set: { on in if on { hidden.remove(h.id) } else { hidden.insert(h.id) } }))
            }
        } label: {
            Label {
                HStack(spacing: 4) {
                    Text(hidden.isEmpty ? "All Habits" : "\(habits.count - hidden.count) of \(habits.count) Habits")
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                }
            } icon: {
                Image(systemName: hidden.isEmpty
                    ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func pick(_ r: ProgressRange) {
        if r == .custom { choosingDates = true } else { range = r }
    }
}

/// A key to the squares.
struct Legend: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let color = app.accent
        let samples = Group {
            item(RoundedRectangle(cornerRadius: 4).fill(color).padding(3), "Done every scheduled day")
            item(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.2)).padding(3), "Some days")
            item(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary).padding(3), "No days")
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Each square shows:").fontWeight(.semibold)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { samples }
                VStack(alignment: .leading, spacing: 6) { samples }
            }
            // Same proportions as the grid: a whole-point gap and line, so
            // the ring lands on exact pixels and stays centred.
            item(
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color)
                    .padding(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(.primary, lineWidth: 1)),
                "A ring means you changed your version of the habit that week")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Every sample sits in the same 20-point slot, so the labels line up
    /// whether or not the sample has a ring around it.
    private func item(_ sample: some View, _ text: String) -> some View {
        HStack(spacing: 6) {
            sample.frame(width: 20, height: 20)
            Text(text)
        }
    }
}

struct WeekGrid: View {
    let habits: [Habit]
    let weeks: [Date]
    let today: Date
    @Environment(AppModel.self) private var app
    /// The square whose details are showing ("habit id|week").
    @State private var showing: String?
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// The ring around a week where the version changed: its width and the
    /// gap between it and the square. Its corners follow the square's.
    private let squareRadius: CGFloat = 8
    private let ringWidth: CGFloat = 1, ringGap: CGFloat = 2
    private var ringInset: CGFloat { ringWidth + ringGap }

    private let cell: CGFloat = 34, gap: CGFloat = 6, header: CGFloat = 40, section: CGFloat = 34

    var body: some View {
        let narrow = sizeClass == .compact
        let names: CGFloat = narrow ? 140 : 250
        let row: CGFloat = narrow ? 72 : 58
        let sections = [("BUILDING", habits.filter { !$0.isQuit }), ("BREAKING", habits.filter(\.isQuit))]
            .filter { !$0.1.isEmpty }

        HStack(alignment: .top, spacing: 0) {
            // Names and how each habit is going. Stays put.
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: header)
                ForEach(sections, id: \.0) { title, list in
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(height: section, alignment: .bottomLeading)
                    ForEach(list) { h in
                        nameCell(h, narrow: narrow)
                            .frame(width: names, height: row, alignment: .leading)
                    }
                }
            }
            .frame(width: names)

            // The weeks. Opens on the latest; older ones are a swipe away.
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: gap) {
                            ForEach(Array(weeks.enumerated()), id: \.offset) { i, week in
                                weekLabel(i, week).frame(width: cell, height: header, alignment: .bottom)
                            }
                        }
                        ForEach(sections, id: \.0) { _, list in
                            Color.clear.frame(height: section)
                            ForEach(list) { h in
                                HStack(spacing: gap) {
                                    ForEach(Array(weeks.enumerated()), id: \.offset) { i, week in
                                        square(h, week).id(i)
                                    }
                                }
                                .frame(height: row)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .onAppear { proxy.scrollTo(weeks.count - 1, anchor: .trailing) }
                .onChange(of: weeks.count) { _, n in proxy.scrollTo(n - 1, anchor: .trailing) }
            }
        }
        // Every other row gets a faint band, so each habit's name is easy
        // to follow across to its weeks. One layer behind both columns, so
        // a band runs the full width even while the weeks scroll.
        .background(alignment: .topLeading) {
            VStack(spacing: 0) {
                Color.clear.frame(height: header)
                ForEach(sections, id: \.0) { _, list in
                    Color.clear.frame(height: section)
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, _ in
                        RoundedRectangle(cornerRadius: 10)
                            .fill(i.isMultiple(of: 2) ? Color.primary.opacity(0.05) : .clear)
                            .frame(height: row)
                    }
                }
            }
            .padding(.horizontal, -8)
        }
    }

    /// The habit's icon and name, how it's going, and over what period:
    /// "Going strong", then "27 of the last 28 days".
    private func nameCell(_ h: Habit, narrow: Bool) -> some View {
        let s = app.repo.strength(h)
        let count = s.level == .justStarted ? "" : recentLabel(h, s)
        return HStack(alignment: .top, spacing: 8) {
            HabitGlyph(icon: h.icon, color: h.color, size: 15)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(h.name).font(.subheadline).lineLimit(1)
                Text(s.level.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(s.level.color)
                if !count.isEmpty {
                    Text(count)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(narrow ? 2 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.trailing, 8)
    }

    /// "27 of the last 28 days" for a daily habit; "10 of 12 days in the
    /// last 4 weeks" for one that isn't every day. Says "clear" for habits
    /// being broken.
    private func recentLabel(_ h: Habit, _ s: Strength) -> String {
        let clear = h.isQuit ? " clear" : ""
        return s.scheduled == 28
            ? "\(s.done) of the last 28 days\(clear)"
            : "\(s.done) of \(s.scheduled) days\(clear) in the last 4 weeks"
    }

    /// The month's name where a new month starts, then the day each week
    /// starts on.
    private func weekLabel(_ i: Int, _ week: Date) -> some View {
        let cal = Days.calendar
        let newMonth = i == 0 || cal.component(.month, from: weeks[i - 1]) != cal.component(.month, from: week)
        let thisWeek = week <= today && today < Days.add(week, 7)
        return VStack(alignment: .leading, spacing: 2) {
            Text(newMonth ? week.formatted(.dateTime.month(.abbreviated)) : " ")
                .font(.caption2.weight(.semibold))
                .fixedSize()
                .frame(width: cell, alignment: .leading)
            Text("\(cal.component(.day, from: week))")
                .font(.caption2.weight(thisWeek ? .bold : .regular))
                .foregroundStyle(thisWeek ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: cell)
        }
        .foregroundStyle(.secondary)
    }

    private func square(_ h: Habit, _ week: Date) -> some View {
        let w = app.repo.weekRecord(h, weekStart: week)
        let perfect = w.scheduled > 0 && w.done == w.scheduled
        let change = changeIn(h, week)
        let changed = change?.to
        let key = "\(h.id)|\(Days.key(week))"
        let thisWeek = week <= today && today < Days.add(week, 7)
        let fill: AnyShapeStyle =
            w.scheduled == 0 || w.done == 0 ? AnyShapeStyle(.clear)
            : perfect ? AnyShapeStyle(h.tint) : AnyShapeStyle(h.tint.opacity(0.2))
        let inner = RoundedRectangle(cornerRadius: squareRadius, style: .continuous)
        let description = w.scheduled == 0
            ? "not due"
            : daysLabel(h, w.done, w.scheduled) + (thisWeek ? " so far" : "")

        return ZStack {
            inner.fill(fill)
            if w.scheduled == 0 || w.done == 0 {
                inner.strokeBorder(Color.secondary.opacity(w.scheduled == 0 ? 0.12 : 0.3))
            }
            if w.scheduled > 0 {
                Text("\(w.done)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(perfect ? AnyShapeStyle(.white) : w.done == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            }
        }
        .frame(width: cell, height: cell)
        // The ring sits outside the square, in the space between squares,
        // so a changed week's square and number stay the same size.
        .overlay {
            if changed != nil {
                RoundedRectangle(cornerRadius: squareRadius + ringInset, style: .continuous)
                    .strokeBorder(.primary, lineWidth: ringWidth)
                    .padding(-ringInset)
            }
        }
        .contentShape(.rect)
        .onTapGesture { showing = key }
        .popover(isPresented: Binding(get: { showing == key }, set: { if !$0 { showing = nil } })) {
            WeekDetails(habit: h, title: thisWeek ? "This week" : "Week of \(shortDate(week))",
                description: description, change: change)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityElement()
        .accessibilityLabel("\(h.name), \(thisWeek ? "this week" : "week of \(shortDate(week))")")
        .accessibilityValue(description
            + (change.map { ". You changed your version from \($0.from) to \($0.to)" } ?? ""))
        .accessibilityAddTraits(.isButton)
    }

    /// How a habit's version changed during a week, if it did: from what,
    /// to what, and on which day.
    private func changeIn(_ h: Habit, _ week: Date) -> VersionChange? {
        let history = h.plan.sizeHistory
        for i in history.indices.dropFirst() {
            if let since = Days.parse(history[i].since), since >= week, since < Days.add(week, 7) {
                return VersionChange(from: history[i - 1].text, to: history[i].text, on: since)
            }
        }
        return nil
    }
}

struct VersionChange {
    let from: String
    let to: String
    let on: Date
}

/// What a square in the Progress grid shows when tapped.
private struct WeekDetails: View {
    let habit: Habit
    let title: String
    let description: String
    let change: VersionChange?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(habit.name).font(.headline)
            } icon: {
                HabitGlyph(icon: habit.icon, color: habit.color)
            }
            Text("\(title): \(description)")
                .foregroundStyle(.secondary)
            if let change {
                Divider()
                Text("You changed your version on \(change.on.formatted(.dateTime.weekday(.wide).month(.wide).day()))")
                    .font(.subheadline.weight(.semibold))
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("From").foregroundStyle(.secondary)
                        Text(change.from)
                    }
                    GridRow {
                        Text("To").foregroundStyle(.secondary)
                        Text(change.to).fontWeight(.semibold)
                    }
                }
                .font(.subheadline)
            }
        }
        .padding(16)
        .frame(minWidth: 220, maxWidth: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
