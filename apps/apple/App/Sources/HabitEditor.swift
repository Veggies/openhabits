import HabitsCore
import SwiftUI

/// Creates or edits a habit. The Atomic Habits sections only show when the
/// framework is on, or the habit already uses them.
struct HabitEditor: View {
    let existing: Habit?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind = HabitKind.build
    @State private var color = habitColors[7]
    @State private var icon = "check"
    @State private var weekdays: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
    @State private var hasTime = false
    @State private var time = TimeOfDay(hour: 7, minute: 0).date()
    @State private var duration = 15
    @State private var remind = true
    @State private var plan: [String: String] = [:]
    @State private var startSmall = false
    @State private var choosingIcon = false
    @State private var loaded = false

    var body: some View {
        let repo = app.repo
        let framework = true

        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $kind) {
                        Text("Build a habit").tag(HabitKind.build)
                        Text("Break a habit").tag(HabitKind.quit)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    HStack(spacing: 14) {
                        Button {
                            choosingIcon = true
                        } label: {
                            HabitIcon(icon: icon, color: color, size: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Choose icon")
                        TextField(kind == .build ? "Habit, e.g. Read" : "Habit to break, e.g. Scrolling in bed",
                            text: $name)
                            .font(.title3)
                    }
                    ColorRow(selected: $color)
                }

                if kind == .build {
                    Section("Repeat on") {
                        WeekdayPicker(selected: $weekdays, weekStart: repo.weekStart)
                    }
                }

                Section {
                    Toggle("At a set time", isOn: $hasTime.animation())
                    if hasTime {
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        Toggle("Remind me", isOn: $remind)
                        Picker("How long", selection: $duration) {
                            ForEach(Array(Set([5, 10, 15, 30, 45, 60, 90, 120, duration])).sorted(), id: \.self) {
                                Text(durationLabel($0)).tag($0)
                            }
                        }
                    }
                } footer: {
                    Text(hasTime
                        ? "Reminders need to be on in Settings → Reminders. It can also show up in your calendar app, from Settings → Show Habits in Your Calendar App (once you're connected to your server)."
                        : "Give it a time to get a reminder, and to see it in your calendar app.")
                }

                if framework {
                    Section {
                        field("identity", "I am a person who…")
                    } header: {
                        Text("Who do you want to become?")
                    } footer: {
                        Text("Each time you do the habit, it's a vote for becoming this person. Everything from here on is optional, so just fill in what helps you.")
                    }
                    if kind == .build { buildSections } else { breakSections }
                }

                if let existing {
                    Section {
                        Button("Archive Habit") {
                            repo.updateHabit(existing.id, ["archived": true])
                            dismiss()
                        }
                    } footer: {
                        Text("Archiving hides it but keeps its history. To delete it, swipe left on it in the list.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? "New Habit" : "Edit Habit")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $choosingIcon) {
                IconPicker(selected: $icon, color: color)
            }
            .onAppear(perform: load)
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 600)
        #endif
    }

    @ViewBuilder
    private var buildSections: some View {
        Section {
            field("location", "Where, e.g. In the kitchen")
            field("stackAfter", "After I…, e.g. pour my morning coffee")
        } header: {
            LawHeader(number: 1, title: "Make it obvious")
        } footer: {
            Text("Tie it to something you already do every day, like making your morning coffee.")
        }
        Section {
            field("bundle", "Pair it with something you enjoy")
        } header: {
            LawHeader(number: 2, title: "Make it attractive")
        }
        Section {
            Toggle(isOn: $startSmall.animation()) {
                Text("Start small and grow it")
                Text("Begin with a tiny version of the habit and let it grow over time.")
            }
            if startSmall {
                field("twoMinute", "Your version for now, e.g. Read one page")
                if let existing, let current = app.repo.habit(existing.id), current.plan.sizeSettled {
                    Button("Start Checking In Again") { app.repo.settleSize(current, settled: false) }
                }
            }
        } header: {
            LawHeader(number: 3, title: "Make it easy")
        } footer: {
            if startSmall { Text(buildUpExplanation) }
        }
        Section {
            field("reward", "Reward right after, e.g. A square of chocolate")
        } header: {
            LawHeader(number: 4, title: "Make it satisfying")
        }
    }

    @ViewBuilder
    private var breakSections: some View {
        Section {
            field("invisible", "Remove the cue, e.g. Charge my phone outside the bedroom")
        } header: {
            LawHeader(number: 1, title: "Make it invisible")
        }
        Section {
            field("unattractive", "Reframe it, e.g. Remember how tired I feel the next day")
        } header: {
            LawHeader(number: 2, title: "Make it unattractive")
        }
        Section {
            field("difficult", "Add friction, e.g. Log out of the app after every use")
        } header: {
            LawHeader(number: 3, title: "Make it difficult")
        }
        Section {
            field("unsatisfying", "Accountability, e.g. Tell Sam if I slip")
            field("contract", "Habit contract, e.g. If I slip, I'll do the dishes for a week")
        } header: {
            LawHeader(number: 4, title: "Make it unsatisfying")
        } footer: {
            Text("A habit contract is a promise to someone, with a real cost if you break it. It helps the change stick.")
        }
    }

    private func field(_ key: String, _ prompt: String) -> some View {
        TextField(prompt, text: Binding(get: { plan[key] ?? "" }, set: { plan[key] = $0 }), axis: .vertical)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let h = existing else { return }
        name = h.name
        kind = h.kind
        color = h.color
        icon = h.icon
        weekdays = h.weekdays
        duration = h.duration
        remind = h.remind
        if let t = TimeOfDay(h.plan.time) {
            hasTime = true
            time = t.date()
        }
        for f in HabitPlan.fieldNames { plan[f] = h.plan.value(f) }
        startSmall = !h.plan.twoMinute.isEmpty
    }

    private func save() {
        let repo = app.repo
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var fields: Fields = [
            "name": .string(trimmed),
            "color": .int(color),
            "icon": .string(icon),
            "kind": .string(kind.rawValue),
            "weekdays": .array(weekdays.sorted().map { .int($0) }),
            "duration": .int(duration),
            "remind": .bool(remind),
        ]
        for f in HabitPlan.fieldNames where f != "time" {
            fields[f] = .string((plan[f] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !startSmall { fields["twoMinute"] = "" }
        fields["time"] = .string(hasTime ? TimeOfDay(time).text : "")
        if let existing, let current = repo.habit(existing.id) {
            // A changed version joins the habit's history.
            let version = fields["twoMinute"]?.string ?? ""
            if !version.isEmpty && !current.plan.twoMinute.isEmpty {
                fields.merge(repo.resizeFields(current, to: version)) { _, b in b }
            }
            repo.updateHabit(existing.id, fields)
        } else {
            repo.createHabit(fields)
        }
        dismiss()
    }
}

struct LawHeader: View {
    let number: Int
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(.tint)
            Text(title)
        }
    }
}

struct ColorRow: View {
    @Binding var selected: Int

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 10) {
            ForEach(habitColors, id: \.self) { c in
                Button {
                    selected = c
                } label: {
                    Circle()
                        .fill(Color(argb: c))
                        .frame(width: 30, height: 30)
                        .overlay {
                            if c == selected {
                                Circle().strokeBorder(.background, lineWidth: 3)
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(c == selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

/// Seven day toggles, in the person's week order.
struct WeekdayPicker: View {
    @Binding var selected: Set<Int>
    let weekStart: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Days.order(startingOn: weekStart), id: \.self) { d in
                let on = selected.contains(d)
                Button {
                    var next = selected
                    if on { next.remove(d) } else { next.insert(d) }
                    if !next.isEmpty { selected = next }
                } label: {
                    Text(weekdayShort(d).prefix(3))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

struct IconPicker: View {
    @Binding var selected: String
    let color: Int
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @FocusState private var typing: Bool

    /// A few to start with; any emoji can be typed or pasted.
    private let suggestions = [
        "📚", "🏃", "🚶", "🧘", "💧", "😴", "🥗", "🍎", "💪", "🚴", "✍️", "🎸",
        "🎨", "🧹", "🌱", "🐶", "🙏", "💊", "🦷", "☀️", "📵", "🚭", "💰", "🧠",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Emoji").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 12)], spacing: 12) {
                        ForEach(suggestions, id: \.self) { emoji in
                            tile(selected: selected == emoji) {
                                Text(emoji).font(.system(size: 30))
                            } action: {
                                choose(emoji)
                            }
                            .accessibilityLabel(emoji)
                        }
                    }
                    HStack {
                        TextField("Or type any emoji", text: $typed)
                            .focused($typing)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: typed) { _, text in
                                if let emoji = lastEmoji(in: text) { choose(emoji) }
                            }
                        #if os(macOS)
                        Button("Emoji & Symbols") {
                            typing = true
                            NSApp.orderFrontCharacterPalette(nil)
                        }
                        #endif
                    }
                    Text("Symbols").font(.headline).padding(.top, 8)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 12)], spacing: 12) {
                        ForEach(habitSymbols, id: \.key) { item in
                            tile(selected: item.key == selected) {
                                Image(systemName: item.symbol)
                                    .font(.title2)
                                    .foregroundStyle(item.key == selected ? .white : Color(argb: color))
                            } action: {
                                choose(item.key)
                            }
                            .accessibilityLabel(item.key)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Choose an Icon")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    private func choose(_ icon: String) {
        selected = icon
        dismiss()
    }

    private func tile(selected on: Bool, @ViewBuilder content: () -> some View, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            content()
                .frame(width: 56, height: 56)
                .background(on ? Color(argb: color) : Color(argb: color).opacity(0.12), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
