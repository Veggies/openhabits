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

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                #if os(macOS)
                HStack(spacing: 12) {
                    Text("Progress").font(.largeTitle.bold())
                    Spacer()
                    datePicker
                    if habits.count > 1 { habitFilter(habits) }
                }
                #endif
                Text("Here's how each habit has gone, week by week. The number in each square is how many days you did it that week. For habits you're trying to break, it's how many days you went without it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if habits.isEmpty {
                    ContentUnavailableView("Nothing to show yet", systemImage: "square.grid.3x3",
                        description: Text("Once you've started a habit, you'll see how each week went here."))
                } else if shown.isEmpty {
                    ContentUnavailableView("No habits picked", systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Choose which habits to show with the filter button."))
                } else {
                    Legend()
                    WeekGrid(habits: shown, weeks: Array(weeks), today: today)
                }
            }
            .padding()
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Progress")
        .largeTitle()
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { datePicker }
            if habits.count > 1 {
                ToolbarItem(placement: .primaryAction) { habitFilter(habits) }
            }
        }
        #endif
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

    private var datePicker: some View {
        Picker("Dates", selection: Binding(get: { range }, set: { pick($0) })) {
            ForEach(ProgressRange.allCases) { r in
                Text(r == .custom && range == .custom
                    ? "\(shortDate(customFrom)) – \(shortDate(customTo))" : r.rawValue)
                    .tag(r)
            }
        }
        .pickerStyle(.menu)
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
            Label(hidden.isEmpty ? "All habits" : "\(habits.count - hidden.count) of \(habits.count) habits",
                systemImage: hidden.isEmpty
                    ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
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
            item(RoundedRectangle(cornerRadius: 4).fill(color), "Done every scheduled day")
            item(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.2)), "Some days")
            item(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary), "No days")
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Each square shows:").fontWeight(.semibold)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { samples }
                VStack(alignment: .leading, spacing: 6) { samples }
            }
            item(
                RoundedRectangle(cornerRadius: 5).strokeBorder(.primary, lineWidth: 1.5)
                    .overlay(RoundedRectangle(cornerRadius: 3).fill(color).padding(3)),
                "A ring means you changed your version of the habit that week")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func item(_ sample: some View, _ text: String) -> some View {
        HStack(spacing: 6) {
            sample.frame(width: 16, height: 16)
            Text(text)
        }
    }
}

struct WeekGrid: View {
    let habits: [Habit]
    let weeks: [Date]
    let today: Date
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass

    private let cell: CGFloat = 34, gap: CGFloat = 6, header: CGFloat = 40, section: CGFloat = 34

    var body: some View {
        let narrow = sizeClass == .compact
        let names: CGFloat = narrow ? 120 : 230
        let row: CGFloat = narrow ? 60 : 50
        let sections = [("BUILDING", habits.filter { !$0.isQuit }), ("BREAKING", habits.filter(\.isQuit))]
            .filter { !$0.1.isEmpty }

        HStack(alignment: .top, spacing: 0) {
            // Names and how each habit is going. Stays put.
            VStack(alignment: .leading, spacing: 0) {
                Text("Last 4 weeks")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(height: header, alignment: .bottomLeading)
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
                    .padding(.trailing, 4)
                }
                .onAppear { proxy.scrollTo(weeks.count - 1, anchor: .trailing) }
                .onChange(of: weeks.count) { _, n in proxy.scrollTo(n - 1, anchor: .trailing) }
            }
        }
    }

    private func nameCell(_ h: Habit, narrow: Bool) -> some View {
        let s = app.repo.strength(h)
        let count = s.level == .justStarted ? "" : daysLabel(h, s.done, s.scheduled)
        return VStack(alignment: .leading, spacing: 1) {
            Text(h.name).font(.subheadline).lineLimit(1)
            if narrow {
                if !count.isEmpty { Text(count).font(.caption).foregroundStyle(.secondary) }
                Text(s.level.label).font(.caption.weight(.semibold)).foregroundStyle(s.level.color)
            } else {
                Text("\(Text(count.isEmpty ? "" : "\(count) · ").foregroundStyle(.secondary))\(Text(s.level.label).fontWeight(.semibold).foregroundStyle(s.level.color))")
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .padding(.trailing, 8)
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
        let changed = changeIn(h, week)
        let thisWeek = week <= today && today < Days.add(week, 7)
        let fill: AnyShapeStyle =
            w.scheduled == 0 || w.done == 0 ? AnyShapeStyle(.clear)
            : perfect ? AnyShapeStyle(h.tint) : AnyShapeStyle(h.tint.opacity(0.2))
        let inner = RoundedRectangle(cornerRadius: changed == nil ? 8 : 5)
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
                    .font((changed == nil ? Font.subheadline : .caption).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(perfect ? AnyShapeStyle(.white) : w.done == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            }
        }
        .padding(changed == nil ? 0 : 3)
        .overlay {
            if changed != nil {
                RoundedRectangle(cornerRadius: 10).strokeBorder(.primary, lineWidth: 2)
            }
        }
        .frame(width: cell, height: cell)
        .help("\(h.name)\n\(thisWeek ? "This week" : "Week of \(shortDate(week))"): \(description)"
            + (changed.map { "\nYou changed your version to \"\($0)\"" } ?? ""))
        .accessibilityElement()
        .accessibilityLabel("\(h.name), \(thisWeek ? "this week" : "week of \(shortDate(week))")")
        .accessibilityValue(description + (changed.map { ". You changed your version to \($0)" } ?? ""))
    }

    /// The version a habit changed to during a week, if any.
    private func changeIn(_ h: Habit, _ week: Date) -> String? {
        for v in h.plan.sizeHistory.dropFirst() {
            if let since = Days.parse(v.since), since >= week, since < Days.add(week, 7) { return v.text }
        }
        return nil
    }
}
