#if os(macOS)
import HabitsCore
import SwiftUI

/// The Mac window's tabs, shown in the toolbar.
enum MacTab: Hashable {
    case today, progress, reflect, focus
}

/// The Mac window: tabs in the toolbar, the same ones as on iPhone. The
/// window title is hidden, since the tabs already say where you are; that
/// keeps the toolbar steady as you move between them.
struct MacMainView: View {
    @Environment(AppModel.self) private var app
    @State private var editing: EditorTarget?
    /// Tabs opened so far, kept alive (see body).
    @State private var visited: Set<MacTab> = []

    private func closePreview() {
        withAnimation(.smooth(duration: 0.32)) { app.previewHabit = nil }
    }

    @ViewBuilder private func page(_ tab: MacTab) -> some View {
        switch tab {
        case .today:
            // A habit slides in from the right and covers most of the
            // window. The list stays visible, blurred, on the left:
            // click it (or press Esc) to go back.
            GeometryReader { geo in
                ZStack(alignment: .trailing) {
                    NavigationStack { HabitsView() }
                        .blur(radius: app.previewHabit == nil ? 0 : 10)
                        .allowsHitTesting(app.previewHabit == nil)
                    if let id = app.previewHabit {
                        Color.black.opacity(0.2)
                            .contentShape(.rect)
                            .onTapGesture { closePreview() }
                            .help("Back to Today")
                            .transition(.opacity)
                            .zIndex(1)
                        HabitDetailView(habitId: id) { closePreview() }
                            .id(id)
                            .frame(width: min(geo.size.width - 120, max(560, geo.size.width * 0.75)))
                            .frame(maxHeight: .infinity)
                            .background(.background)
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18))
                            .shadow(color: .black.opacity(0.3), radius: 30, x: -6)
                            .transition(.move(edge: .trailing))
                            // Keeps the page on top while it slides away;
                            // otherwise it drops behind the list and vanishes.
                            .zIndex(2)
                    }
                }
                // A GeometryReader puts its content in the top-left
                // corner at its natural size; fill the window instead.
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .animation(.smooth(duration: 0.32), value: app.previewHabit)
            .onExitCommand { closePreview() }
        case .progress: NavigationStack { ProgressScreen() }
        case .reflect: NavigationStack { ReflectView() }
        case .focus: NavigationStack { FocusView() }
        }
    }

    private let tabs: [(tab: MacTab, title: String)] = [
        (.today, "Today"), (.progress, "Progress"), (.reflect, "Reflect"), (.focus, "Focus"),
    ]

    var body: some View {
        @Bindable var app = app
        let focus = app.focus

        // Each tab is built the first time it's opened, then kept and only
        // hidden while another is showing. Rebuilding a tab on every switch
        // (laying out the habit list row by row, or measuring the whole
        // Progress grid) made switching noticeably laggy.
        ZStack {
            ForEach(tabs.map(\.tab).filter { visited.contains($0) || $0 == app.macTab }, id: \.self) { tab in
                let showing = tab == app.macTab
                page(tab)
                    .opacity(showing ? 1 : 0)
                    .allowsHitTesting(showing)
                    .accessibilityHidden(!showing)
            }
        }
        .onChange(of: app.macTab, initial: true) { _, tab in visited.insert(tab) }
        // Builds the other tabs just after the window first shows, so even
        // the first switch to each one is quick.
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            visited.formUnion(tabs.map(\.tab))
        }
        .toolbar(removing: .title)
        .toolbar {
            // The same tabs on every screen, so the toolbar never shifts.
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $app.macTab) {
                    ForEach(tabs, id: \.tab) { item in
                        Text(item.title).tag(item.tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            // While a session runs, its countdown stays in reach from any tab.
            if (focus.running || focus.paused) && app.macTab != .focus {
                ToolbarItem(placement: .navigation) {
                    Button {
                        app.macTab = .focus
                    } label: {
                        FocusMenuLabel()
                    }
                    .help("Go to Focus")
                }
            }
        }
        .sheet(item: $editing) { HabitEditor(existing: $0.habit) }
        .onChange(of: app.newHabitRequested) { _, requested in
            if requested {
                editing = .new
                app.newHabitRequested = false
            }
        }
        // A habit that's archived or deleted (here or on another device)
        // closes its preview.
        .onChange(of: app.repo.habits.map(\.id)) { _, ids in
            if let open = app.previewHabit, !ids.contains(open) { app.previewHabit = nil }
        }
    }
}

/// The Focus timer in the menu bar, for quick access while working in
/// other apps. Shows the countdown while it runs.
struct FocusMenuLabel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let focus = app.focus
        if focus.running || focus.paused {
            let left = Int(focus.remaining(at: focus.now).rounded(.up))
            Text(String(format: "%@ %d:%02d", focus.paused ? "⏸" : "⏱", left / 60, left % 60))
                .monospacedDigit()
        } else {
            Image(systemName: "timer")
        }
    }
}

/// What opens from the menu bar: the timer and today's tomatoes.
struct FocusMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 18) {
            TimerPanel(focus: app.focus, compact: true)
            TomatoRow()
        }
        .padding(20)
        .frame(width: 340)
    }
}
#endif
