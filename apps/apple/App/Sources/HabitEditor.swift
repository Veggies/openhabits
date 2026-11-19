import HabitsCore
import SwiftUI

/// Creates or edits a habit, including its Atomic Habits plan.
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
    /// The form as it opened, to save only what changed.
    @State private var loadedFields: Fields = [:]

    var body: some View {
        let repo = app.repo

        NavigationStack {
            ScrollViewReader { scroller in
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
                        HintField(kind == .build ? "Habit, e.g. Read" : "Habit to break, e.g. Scrolling in bed",
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

                Section {
                    field("identity", "e.g. a person who reads every day")
                } header: {
                    Text("Who do you want to become?")
                } footer: {
                    Text("Each time you do the habit, it's a vote for becoming this person. Everything from here on is optional, so just fill in what helps you.")
                }
                .id("plan")
                if kind == .build { buildSections } else { breakSections }

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
            #if DEBUG
            // -openScreen editorPlan: opens scrolled to the Atomic Habits
            // part, for screenshots.
            .task {
                if UserDefaults.standard.string(forKey: "openScreen") == "editorPlan" {
                    try? await Task.sleep(for: .milliseconds(300))
                    scroller.scrollTo("plan", anchor: .top)
                }
            }
            #endif
            }
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
            field("stackAfter", "e.g. pour my morning coffee")
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
        HintField(prompt, text: Binding(get: { plan[key] ?? "" }, set: { plan[key] = $0 }), axis: .vertical,
                  prefix: HabitPlan.leads[key])
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
        loadedFields = currentFields()
    }

    /// The form as fields, the way they're saved.
    private func currentFields() -> Fields {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
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
            fields[f] = .string(HabitPlan.tidy(f, plan[f] ?? ""))
        }
        if !startSmall { fields["twoMinute"] = "" }
        fields["time"] = .string(hasTime ? TimeOfDay(time).text : "")
        return fields
    }

    private func save() {
        let repo = app.repo
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let fields = currentFields()
        if let existing, let current = repo.habit(existing.id) {
            // Only what the person changed: saving everything would undo
            // edits another device made to other fields while this editor
            // was open. (Matches habit_editor.dart.)
            var changed = fields.filter { loadedFields[$0.key] != $0.value }
            // A changed version joins the habit's history.
            let version = fields["twoMinute"]?.string ?? ""
            if changed["twoMinute"] != nil && !version.isEmpty && !current.plan.twoMinute.isEmpty {
                changed.merge(repo.resizeFields(current, to: version)) { _, b in b }
            }
            repo.updateHabit(existing.id, changed)
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
    /// True while the system's emoji picker (Mac) or emoji keyboard
    /// (iPhone and iPad) is open for choosing any emoji.
    @State private var pickingAny = false

    /// A few to start with; "More Emoji" opens the system's own picker for
    /// any other. There's no box to type into: only an emoji is kept.
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
                    Button("More Emoji", systemImage: "face.smiling") {
                        pickingAny = true
                        #if os(macOS)
                        NSApp.orderFrontCharacterPalette(nil)
                        #endif
                    }
                    .background { EmojiCatcher(active: $pickingAny, onEmoji: choose) }
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

/// Receives an emoji from the system's emoji picker without showing a text
/// box. The Mac's Emoji & Symbols window and the iPhone's emoji keyboard
/// both type into whatever is focused, so this is an invisible field that
/// keeps only an emoji and throws away anything else.
#if os(macOS)
private struct EmojiCatcher: NSViewRepresentable {
    @Binding var active: Bool
    let onEmoji: (String) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.textColor = .clear
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.setAccessibilityElement(false)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if active {
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        CGSize(width: 1, height: 1)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: EmojiCatcher
        init(parent: EmojiCatcher) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            let new = field.stringValue
            field.stringValue = ""
            if let emoji = lastEmoji(in: new) {
                parent.active = false
                parent.onEmoji(emoji)
            }
        }

        func controlTextDidEndEditing(_ note: Notification) { parent.active = false }
    }
}
#else
private struct EmojiCatcher: UIViewRepresentable {
    @Binding var active: Bool
    let onEmoji: (String) -> Void

    func makeUIView(context: Context) -> EmojiField {
        let field = EmojiField()
        field.tintColor = .clear
        field.textColor = .clear
        field.autocorrectionType = .no
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.addTarget(context.coordinator, action: #selector(Coordinator.ended), for: .editingDidEnd)
        return field
    }

    func updateUIView(_ field: EmojiField, context: Context) {
        context.coordinator.parent = self
        if active && !field.isFirstResponder {
            DispatchQueue.main.async { field.becomeFirstResponder() }
        } else if !active && field.isFirstResponder {
            DispatchQueue.main.async { field.resignFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject {
        var parent: EmojiCatcher
        init(parent: EmojiCatcher) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            let new = field.text ?? ""
            field.text = ""
            if let emoji = lastEmoji(in: new) {
                parent.active = false
                parent.onEmoji(emoji)
            }
        }

        @objc func ended() { parent.active = false }
    }

    /// Opens straight to the emoji keyboard when there is one.
    final class EmojiField: UITextField {
        override var textInputMode: UITextInputMode? {
            UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
        }
    }
}
#endif
