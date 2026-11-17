import HabitsCore
import SwiftUI

/// Atomic Habits' two reflection tools: a weekly review and the habits
/// scorecard.
struct ReflectView: View {
    enum Page: String, CaseIterable { case review = "Weekly Review", scorecard = "Scorecard" }
    @State private var page = Page.review

    private var picker: some View {
        Picker("Show", selection: $page) {
            ForEach(Page.allCases, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var content: some View {
        Group {
            switch page {
            case .review: WeeklyReviewView()
            case .scorecard: ScorecardView()
            }
        }
    }

    var body: some View {
        #if os(macOS)
        // The Mac's toolbar holds the main tabs, so the switch sits on the page.
        VStack(spacing: 0) {
            picker.padding(.top, 14)
            content
        }
        #else
        content
        .navigationTitle(page.rawValue)
        .largeTitle()
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $page) {
                    ForEach(Page.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        #endif
    }
}

/// A short reflection on the week, with how each habit went. Opens on last
/// week if it hasn't been written yet.
struct WeeklyReviewView: View {
    @Environment(AppModel.self) private var app
    @State private var day: Date?
    @State private var answers: [String: String] = [:]
    @State private var loadedWeek = ""
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        let repo = app.repo
        let today = repo.today
        let shown = day ?? (repo.lastWeekReviewDue ? Days.add(today, -7) : today)
        let start = Days.startOfWeek(shown, firstDay: repo.weekStart)
        let end = Days.add(start, 6)
        let upTo = min(end, today)

        Form {
            Section {
                HStack {
                    Button("Previous Week", systemImage: "chevron.left") { move(shown, -7) }
                        .labelStyle(.iconOnly)
                    Spacer()
                    Text(start <= today && today <= end ? "This week" : "Week of \(shortDate(start))")
                        .font(.headline)
                    Spacer()
                    Button("Next Week", systemImage: "chevron.right") { move(shown, 7) }
                        .labelStyle(.iconOnly)
                        .disabled(end >= today)
                }
                .buttonStyle(.borderless)
            }
            Section("How the week went") {
                ForEach(repo.habits) { h in
                    let rate = repo.completionRate(h, end: upTo, days: Days.between(start, upTo) + 1)
                    LabeledContent {
                        Text("\(Int((rate * 100).rounded()))%\(h.isQuit ? " clear" : "")")
                            .monospacedDigit()
                    } label: {
                        Label {
                            Text(h.name)
                        } icon: {
                            HabitGlyph(icon: h.icon, color: h.color)
                        }
                    }
                }
            }
            ForEach(WeeklyReview.prompts, id: \.id) { prompt in
                Section(prompt.text) {
                    HintField("Write a few words…", text: binding(prompt.id, day: shown), axis: .vertical)
                        .lineLimit(2...8)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Keep the week that opened. Saving last week's review makes it
            // no longer "due", which would otherwise switch the screen to
            // this week mid-sentence. (The Flutter app does the same.)
            if day == nil { day = shown }
            load(shown)
        }
        .onChange(of: Days.key(start)) { _, _ in load(shown) }
        .onDisappear { saveTask?.cancel(); flush(shown) }
    }

    private func binding(_ id: String, day: Date) -> Binding<String> {
        Binding(get: { answers[id] ?? "" }, set: { value in
            answers[id] = value
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(700))
                if !Task.isCancelled { flush(day) }
            }
        })
    }

    private func load(_ day: Date) {
        let review = app.repo.review(day)
        guard review.id != loadedWeek else { return }
        loadedWeek = review.id
        answers = review.answers
    }

    private func flush(_ day: Date) {
        let saved = app.repo.review(day).answers
        for (id, text) in answers where (saved[id] ?? "") != text {
            app.repo.saveReview(day, prompt: id, answer: text)
        }
    }

    private func move(_ from: Date, _ by: Int) {
        saveTask?.cancel()
        flush(from)
        day = Days.add(from, by)
    }
}

/// List what you already do each day and rate each one. The point is
/// awareness, not judgement.
struct ScorecardView: View {
    @Environment(AppModel.self) private var app
    @State private var newItem = ""
    @FocusState private var adding: Bool

    var body: some View {
        let repo = app.repo
        let items = repo.scorecard
        Form {
            Section {
                ForEach(items) { item in
                    ScorecardRow(item: item)
                        .contextMenu {
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                repo.deleteScorecardItem(item.id)
                            }
                        }
                }
                // iPhone: swipe left, or tap Edit, to remove entries.
                .onDelete { offsets in
                    for i in offsets { repo.deleteScorecardItem(items[i].id) }
                }
                HintField("Add something you do, e.g. Check my phone", text: $newItem)
                    .focused($adding)
                    .onSubmit {
                        let text = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        repo.addScorecardItem(text)
                        newItem = ""
                        adding = true
                    }
            } header: {
                Text("Your day, from waking up to going to bed")
            } footer: {
                Text("Rate each one: does it help (+) or hurt (−) the person you want to become, or is it neutral (=)?")
            }
            if !items.isEmpty {
                Section {
                    ForEach(Rating.all, id: \.value) { r in
                        LabeledContent {
                            Text("\(items.filter { $0.rating == r.value }.count)")
                                .monospacedDigit()
                                .fontWeight(.semibold)
                                .foregroundStyle(r.color)
                        } label: {
                            Label {
                                Text(r.total)
                            } icon: {
                                Image(systemName: r.symbol).foregroundStyle(r.color)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .toolbar {
            if !items.isEmpty {
                ToolbarItem(placement: .primaryAction) { EditButton() }
            }
        }
        #endif
    }
}

/// One entry on the scorecard. On the Mac, a remove button appears when
/// you point at it.
private struct ScorecardRow: View {
    let item: ScorecardItem
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(item.text)
            Spacer()
            #if os(macOS)
            Button {
                app.repo.deleteScorecardItem(item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove")
            .accessibilityLabel("Remove \(item.text)")
            .opacity(hovering ? 1 : 0)
            #endif
            RatingPicker(rating: item.rating) { app.repo.rateScorecardItem(item.id, $0) }
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

/// The three scorecard ratings and their colours: green for habits that
/// help, red for ones that need to go, grey for neutral. The + = − signs
/// stay, so the meaning never relies on colour alone.
struct Rating {
    let value: String
    let sign: String
    let symbol: String
    let total: String
    let name: String
    let color: Color

    static let all = [
        Rating(value: "+", sign: "+", symbol: "plus.circle.fill", total: "Helping", name: "Helps", color: .green),
        Rating(value: "=", sign: "=", symbol: "equal.circle.fill", total: "Neutral", name: "Neutral", color: .gray),
        Rating(value: "-", sign: "−", symbol: "minus.circle.fill", total: "Hurting", name: "Hurts", color: .red),
    ]
}

/// + = − as three pills. The chosen one fills with its colour.
struct RatingPicker: View {
    let rating: String
    let onChange: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Rating.all, id: \.value) { r in
                let on = rating == r.value
                Button {
                    withAnimation(.snappy(duration: 0.2)) { onChange(r.value) }
                } label: {
                    Text(r.sign)
                        .font(.body.weight(.bold))
                        .frame(width: 34, height: 26)
                        .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(r.color))
                        .background {
                            Capsule().fill(on ? r.color : r.color.opacity(0.12))
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(r.name)
                .accessibilityAddTraits(on ? .isSelected : [])
                .help(r.name)
            }
        }
    }
}
