import HabitsCore
import SwiftUI

/// First run: welcome, connect to a server (or skip), a short tour of what
/// the app does, then optionally building a first habit step by step. The
/// tour can be shown again from Settings (`replay`).
struct OnboardingView: View {
    let replay: Bool
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    enum Step { case welcome, connect, tour, firstHabit, habit, done }
    @State private var step = Step.welcome

    var body: some View {
        ZStack {
            switch step {
            case .welcome: welcome
            case .connect: connect
            case .tour: TourView { go(.firstHabit) }.transition(.push(from: .trailing))
            case .firstHabit: firstHabit
            case .habit: GuidedHabit { go(.done) }.transition(.push(from: .trailing))
            case .done: done
            }
        }
        .animation(.smooth, value: step)
        #if os(macOS)
        // The Mac draws a solid strip under the title bar when content
        // scrolls beneath it, only as wide as the scroll view. In this
        // narrow column that showed as an odd box at the top of the window;
        // a soft fade has no strip.
        .scrollEdgeEffectStyle(.soft, for: .top)
        #endif
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private func go(_ next: Step) { step = next }

    private var welcome: some View {
        Page(symbol: "checkmark.circle", title: replay ? "OpenHabits" : "Welcome to OpenHabits",
            message: "Build habits that stick, one small step at a time. It's built around the ideas in James Clear's book Atomic Habits, and everything is kept on your own server.")
        {
            Button {
                if replay || app.sync.isConfigured { go(.tour) } else { go(.connect) }
            } label: {
                Text(replay ? "Take the Tour" : "Get Started").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .transition(.opacity)
    }

    private var connect: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Connect to your server")
                    .font(.largeTitle.bold())
                Text("Sign in to sync with your other devices. You can also do this later in Settings.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
            .padding(.top, 48)
            ConnectView { _ in go(.tour) }
                .scrollContentBackground(.hidden)
            Button("Skip, and use it on this device only") { go(.tour) }
                .padding(.bottom, 28)
        }
        .transition(.push(from: .trailing))
    }

    private var firstHabit: some View {
        Page(symbol: "plus.circle", title: "Build your first habit?",
            message: "We'll go through it one step at a time: who you want to become, a small version to start with, and when and where you'll do it. It takes about a minute.")
        {
            Button {
                go(.habit)
            } label: {
                Text("Let's Build One").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            Button {
                go(.done)
            } label: {
                Text("I'll Do It Later").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
        .transition(.push(from: .trailing))
    }

    private var done: some View {
        Page(symbol: "party.popper", title: "You're all set",
            message: "Check in on Today each day, and see how you're doing on the Progress tab. You can take this tour again any time from Settings.")
        {
            Button {
                // Older versions of the Android app still read this choice.
                app.repo.setPrefs(["atomicHabits": true])
                if replay { dismiss() } else { app.onboarded = true }
            } label: {
                Text(replay ? "Done" : "Start Using OpenHabits").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .transition(.push(from: .trailing))
    }
}

/// A quick tour of what the app does, one idea per page, each with a small
/// picture of what you'll see.
private struct TourView: View {
    let onFinish: () -> Void
    @State private var page = 0

    private struct Stop {
        let title: String
        let message: String
        let picture: Picture
    }

    private enum Picture { case checkIn, neverMissTwice, startSmall, breaking, plan, progress, reflect, focus, devices }

    private var stops: [Stop] {
        [
            Stop(title: "Check in each day",
                message: "Each habit shows your last seven days. When you've done it, tap today's circle, the bigger one on the right. Forgot to tick one off? Tap an earlier day, or open the habit to change any day this month.",
                picture: .checkIn),
            Stop(title: "Miss once, but never twice",
                message: "Life happens. Missing one day won't break your streak, but missing two in a row will. If you missed a habit last time, it'll remind you, so you can get back on track today.",
                picture: .neverMissTwice),
            Stop(title: "Start small, then grow it",
                message: "Begin with a version so small you can't say no, like reading one page. Every two weeks, you'll get a quick check-in. If it's sticking, you'll be asked whether it feels too easy. If you've been missing it, you'll get the option to make it smaller for a while.",
                picture: .startSmall),
            Stop(title: "Break bad habits too",
                message: "For a habit you want to quit, check in on the days you stayed clear of it. You'll see your days clean add up, and you can plan ways to make the habit harder to fall into.",
                picture: .breaking),
            Stop(title: "Give each habit a plan",
                message: "Decide who you want to become, when and where you'll do it, what you'll do it straight after, and a small reward. Habits with a time can show up in your calendar app too.",
                picture: .plan),
            Stop(title: "See how it's going",
                message: "The Progress tab shows every habit week by week, and says plainly whether each one is going strong, getting there, or struggling.",
                picture: .progress),
            Stop(title: "Look back each week",
                message: "In Reflect, the weekly review asks a few short questions about your week. The scorecard helps you notice the habits you already have, and whether each one helps or hurts.",
                picture: .reflect),
            Stop(title: "Focus, and earn your tomatoes",
                message: focusMessage,
                picture: .focus),
            Stop(title: "On all your devices",
                message: "Your habits are kept on your own server and stay in sync on your phone and computer. To add a device, go to Settings and show its QR code.",
                picture: .devices),
        ]
    }

    private var focusMessage: String {
        #if os(macOS)
        "The Focus timer helps you work on one thing for 25 minutes. Each session you finish earns a tomato toward your daily goal. Start one from any habit, and find the timer in the menu bar too."
        #else
        "The Focus timer helps you work on one thing for 25 minutes. Each session you finish earns a tomato toward your daily goal. You can start one straight from a habit."
        #endif
    }

    var body: some View {
        let stop = stops[page]
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip Tour", action: onFinish)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    picture(stop.picture)
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)
                        .background(.tint.opacity(0.08), in: .rect(cornerRadius: 28))
                    Text(stop.title).font(.largeTitle.bold())
                    Text(stop.message).font(.title3).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28)
                .padding(.top, 12)
                .id(page)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .scrollBounceBehavior(.basedOnSize)

            HStack(spacing: 6) {
                ForEach(stops.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == page ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .frame(width: i == page ? 18 : 7, height: 7)
                }
            }
            .animation(.snappy, value: page)
            .padding(.vertical, 14)
            .accessibilityElement()
            .accessibilityLabel("Page \(page + 1) of \(stops.count)")

            HStack {
                if page > 0 {
                    Button("Back") { withAnimation(.smooth) { page -= 1 } }
                        .buttonStyle(.glass)
                }
                Spacer()
                Button(page == stops.count - 1 ? "Continue" : "Next") {
                    if page == stops.count - 1 { onFinish() } else { withAnimation(.smooth) { page += 1 } }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    // MARK: Pictures, made from the same pieces the app uses

    @ViewBuilder
    private func picture(_ p: Picture) -> some View {
        switch p {
        case .checkIn:
            HStack(spacing: 10) {
                ForEach(0..<7, id: \.self) { i in
                    let today = i == 6
                    ZStack {
                        Circle().strokeBorder(today ? Color.accentColor : .green, lineWidth: today ? 3 : 2)
                        if !today && i != 2 {
                            Circle().fill(.green)
                            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                    .frame(width: today ? 40 : 30, height: today ? 40 : 30)
                }
            }
            .tint(.green)
        case .neverMissTwice:
            VStack(spacing: 14) {
                Label("12 days", systemImage: "flame.fill")
                    .font(.title.bold())
                    .foregroundStyle(.orange)
                Text("You missed this last time")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.14), in: .capsule)
            }
        case .startSmall:
            HStack(spacing: 10) {
                versionPill("Read one page", faded: true)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                versionPill("Read five pages", faded: false)
            }
        case .breaking:
            VStack(spacing: 10) {
                Image(systemName: "shield.fill").font(.system(size: 54)).foregroundStyle(.green)
                Text("8 days clean").font(.title2.bold())
            }
        case .plan:
            Text("After I pour my coffee, I will read one page on the couch.")
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
                .padding(20)
                .frame(maxWidth: 360)
                .background(.background, in: .rect(cornerRadius: 18))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        case .progress:
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach([[3, 5, 7, 7, 6, 7], [2, 4, 3, 5, 4, 5], [1, 2, 2, 3, 4, 6]], id: \.self) { row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, n in
                            Text("\(n)")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(n == 7 ? .white : .primary)
                                .frame(width: 34, height: 34)
                                .background(n == 7 ? Color.accentColor : Color.accentColor.opacity(0.2), in: .rect(cornerRadius: 8))
                        }
                    }
                }
            }
        case .reflect:
            VStack(spacing: 10) {
                ratingLine("Go for a walk", "+", .green)
                ratingLine("Make coffee", "=", .gray)
                ratingLine("Check my phone", "−", .red)
            }
            .frame(maxWidth: 300)
        case .focus:
            VStack(spacing: 14) {
                Text("25:00").font(.system(size: 44, weight: .light, design: .rounded)).monospacedDigit()
                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { i in
                        if i < 3 {
                            Text("🍅").font(.system(size: 26))
                        } else {
                            Circle().strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                                .frame(width: 28, height: 28)
                        }
                    }
                }
            }
        case .devices:
            HStack(spacing: 26) {
                Image(systemName: "iphone")
                Image(systemName: "arrow.triangle.2.circlepath").font(.title).foregroundStyle(.secondary)
                Image(systemName: "server.rack")
                Image(systemName: "arrow.triangle.2.circlepath").font(.title).foregroundStyle(.secondary)
                Image(systemName: "laptopcomputer")
            }
            .font(.system(size: 44))
            .foregroundStyle(.tint)
        }
    }

    private func versionPill(_ text: String, faded: Bool) -> some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(faded ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
            .background(faded ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.tint), in: .capsule)
    }

    private func ratingLine(_ text: String, _ sign: String, _ color: Color) -> some View {
        HStack {
            Text(text)
            Spacer()
            Text(sign)
                .font(.body.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 26)
                .background(color, in: .capsule)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.background, in: .rect(cornerRadius: 12))
    }
}

/// A full-screen step: a big symbol, a title, a message and controls.
private struct Page<Content: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: symbol)
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(.tint)
                    .symbolEffect(.bounce, options: .nonRepeating)
                    .padding(.bottom, 6)
                Text(title).font(.largeTitle.bold())
                Text(message).font(.title3).foregroundStyle(.secondary)
                content
            }
            .padding(28)
            .padding(.top, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// Builds a first habit one law at a time, ending with the plan in one
/// sentence.
private struct GuidedHabit: View {
    let onDone: () -> Void
    @Environment(AppModel.self) private var app
    @State private var page = 0
    @State private var name = ""
    @State private var icon = "book"
    @State private var plan: [String: String] = [:]
    @State private var startSmall = true
    @State private var hasTime = false
    @State private var time = TimeOfDay(hour: 7, minute: 0).date()
    @State private var choosingIcon = false

    private let pages = 5

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: Double(page + 1), total: Double(pages))
                .padding(.horizontal, 28)
                .padding(.top, 24)
            Form {
                switch page {
                case 0:
                    intro("Who do you want to become?",
                        "Think about the kind of person you want to be, not just a result you want. Each time you do the habit, it's a vote for becoming that person.")
                    Section { field("identity", "I am… e.g. a reader") }
                case 1:
                    intro("What small habit proves it?",
                        "Now make it easy. If you like, you can start with a tiny version and grow it over time. That part is up to you.")
                    Section {
                        HStack(spacing: 14) {
                            Button { choosingIcon = true } label: {
                                HabitIcon(icon: icon, color: habitColors[7], size: 44)
                            }
                            .buttonStyle(.plain)
                            HintField("Habit, e.g. Read", text: $name)
                        }
                        Toggle("Start small and grow it", isOn: $startSmall.animation())
                        if startSmall { field("twoMinute", "Your version for now, e.g. Read one page") }
                    } footer: {
                        if startSmall { Text(buildUpExplanation) }
                    }
                case 2:
                    intro("Make it obvious",
                        "Decide exactly when and where, and tie it to something you already do every day.")
                    Section {
                        Toggle("At a set time", isOn: $hasTime.animation())
                        if hasTime { DatePicker("When", selection: $time, displayedComponents: .hourAndMinute) }
                        field("location", "Where, e.g. On the couch")
                        field("stackAfter", "After I…, e.g. pour my morning coffee")
                    }
                case 3:
                    intro("Make it attractive and satisfying",
                        "Pair it with something you enjoy, and give yourself a small reward right after.")
                    Section {
                        field("bundle", "Pair it with, e.g. A cup of tea")
                        field("reward", "Reward, e.g. Tick it off and enjoy the streak")
                    }
                default:
                    intro("Your plan", "Here it is in one sentence:")
                    Section { Text(summary).font(.title3) }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .animation(.smooth, value: page)

            HStack {
                if page > 0 {
                    Button("Back") { page -= 1 }
                        .buttonStyle(.glass)
                }
                Spacer()
                Button("Skip", action: onDone)
                Button(page == pages - 1 ? "Create Habit" : "Next") {
                    if page == pages - 1 { create() } else { page += 1 }
                }
                .buttonStyle(.glassProminent)
                .disabled(page == 1 && name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.large)
            .padding(24)
        }
        .sheet(isPresented: $choosingIcon) { IconPicker(selected: $icon, color: habitColors[7]) }
    }

    private func intro(_ title: String, _ text: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title.bold())
                Text(text).foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    private func field(_ key: String, _ prompt: String) -> some View {
        HintField(prompt, text: Binding(get: { plan[key] ?? "" }, set: { plan[key] = $0 }), axis: .vertical)
    }

    private func value(_ key: String) -> String {
        (plan[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "After I pour my coffee, I will read one page at 7:00 AM on the couch.
    /// Because I am a reader."
    private var summary: String {
        let what = startSmall && !value("twoMinute").isEmpty ? value("twoMinute") : name.trimmingCharacters(in: .whitespaces)
        var parts: [String] = []
        if !value("stackAfter").isEmpty { parts.append("After I \(value("stackAfter")),") }
        parts.append("I will " + (what.isEmpty ? "do my habit" : what.prefix(1).lowercased() + what.dropFirst()))
        if hasTime { parts.append("at \(time.formatted(date: .omitted, time: .shortened))") }
        let place = value("location")
        if !place.isEmpty {
            parts.append(place.range(of: "^(in|on|at) ", options: [.regularExpression, .caseInsensitive]) != nil
                ? place : "at \(place)")
        }
        var sentence = parts.joined(separator: " ") + "."
        sentence = sentence.prefix(1).uppercased() + sentence.dropFirst()
        if !value("identity").isEmpty { sentence += "\n\nBecause I am \(value("identity"))." }
        return sentence
    }

    private func create() {
        var fields: Fields = [
            "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "icon": .string(icon),
            "color": .int(habitColors[7]),
            "kind": "build",
            "weekdays": [1, 2, 3, 4, 5, 6, 7],
        ]
        for f in HabitPlan.fieldNames where f != "time" { fields[f] = .string(value(f)) }
        if !startSmall { fields["twoMinute"] = "" }
        fields["time"] = .string(hasTime ? TimeOfDay(time).text : "")
        app.repo.createHabit(fields)
        onDone()
    }
}
