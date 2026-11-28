#if os(macOS)
import HabitsCore
import SwiftUI

/// The Mac window's tabs, shown in the toolbar.
enum MacTab: Hashable {
    case today, tasks, progress, reflect, focus
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
        case .tasks: NavigationStack { TasksView() }
        case .progress: NavigationStack { ProgressScreen() }
        case .reflect: NavigationStack { ReflectView() }
        case .focus: NavigationStack { FocusView() }
        }
    }

    private let tabs: [(tab: MacTab, title: String)] = [
        (.today, "Today"), (.tasks, "Tasks"), (.progress, "Progress"), (.reflect, "Reflect"), (.focus, "Focus"),
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
            // While a session runs, its countdown stays in reach from any
            // tab, and so does the note once time's up.
            if (focus.running || focus.paused || focus.endedText != nil) && app.macTab != .focus {
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

/// The countdown in the Mac window's toolbar, shown away from the Focus tab.
/// It also says when time's up.
struct FocusMenuLabel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let focus = app.focus
        if focus.running || focus.paused {
            let left = Int(focus.remaining(at: focus.now).rounded(.up))
            Text(String(format: "%@ %d:%02d", focus.paused ? "⏸" : "🍅", left / 60, left % 60))
                .monospacedDigit()
        } else if let text = focus.endedText {
            Text(text)
        }
    }
}

/// The menu bar's version of the label. The menu bar turns a text label
/// into a plain title and drops `.monospacedDigit()`, so each second the
/// digits changed width and the item shifted. Drawing it as a picture keeps
/// the digits even and the item still. The tomato keeps it from looking like
/// the timer macOS puts in the menu bar.
///
/// The countdown stays while the panel is open, but "Time's up" gives way to
/// the panel, which says the same.
struct MenuBarFocusLabel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.displayScale) private var scale

    var body: some View {
        let focus = app.focus
        if focus.running || focus.paused {
            let left = Int(focus.remaining(at: focus.now).rounded(.up))
            let text = String(format: "%d:%02d", left / 60, left % 60)
            Image(nsImage: picture(paused: focus.paused, text: text))
                .accessibilityLabel("\(focus.paused ? "Focus paused" : "Focus timer"), \(text) left")
        } else if !app.menuBarPanelOpen, let text = focus.endedText {
            Image(nsImage: picture(text: text)).accessibilityLabel(text)
        } else {
            Image(nsImage: picture()).accessibilityLabel("Focus timer")
        }
    }

    private func picture(paused: Bool = false, text: String? = nil) -> NSImage {
        let renderer = ImageRenderer(content:
            HStack(spacing: 4) {
                if paused { Image(systemName: "pause.fill") } else { TomatoGlyph() }
                if let text { Text(text).monospacedDigit() }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.black)
            .frame(height: 18)
        )
        renderer.scale = scale
        let image = renderer.nsImage ?? NSImage()
        // A template follows the menu bar's light or dark look.
        image.isTemplate = true
        return image
    }
}

/// A one-colour tomato, with its leaves cut out of the top.
private struct TomatoGlyph: View {
    var body: some View {
        Canvas { context, _ in
            context.fill(Path(ellipseIn: CGRect(x: 0.5, y: 3.5, width: 16, height: 13)), with: .color(.black))
            var leaves = Path()
            let points: [(Double, Double)] = [
                (8.5, 0.5), (9.6, 3.6), (13.6, 3.4), (10.8, 5.4), (11.6, 8.6),
                (8.5, 6.6), (5.4, 8.6), (6.2, 5.4), (3.4, 3.4), (7.4, 3.6),
            ]
            leaves.addLines(points.map { CGPoint(x: $0.0, y: $0.1) })
            leaves.closeSubpath()
            // A clear gap around the leaves, so they stand out from the fruit.
            var gap = context
            gap.blendMode = .destinationOut
            gap.stroke(leaves, with: .color(.black), style: StrokeStyle(lineWidth: 2.2, lineJoin: .round))
            context.fill(leaves, with: .color(.black))
        }
        .frame(width: 17, height: 17)
    }
}

/// What opens from the menu bar: the timer and today's tomatoes.
struct FocusMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 18) {
            TimerPanel(focus: app.focus, compact: true)
            TomatoRow()
            ReadyRewards()
        }
        .padding(20)
        .frame(width: 340)
        .background(PanelWatcher { open in
            app.menuBarPanelOpen = open
            // Opening the panel is how you answer the note, and if time ran
            // out while it was open, you've seen it too.
            app.focus.markEndSeen()
        })
    }
}

/// Says when the menu bar panel opens and closes, and keeps it in one place:
/// lined up with the item's right edge. The menu bar holds that edge still
/// when the label changes, unlike the left one macOS would use. The panel's
/// view stays alive in between, so onAppear and onDisappear can't be relied
/// on.
private struct PanelWatcher: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> WatcherView {
        let view = WatcherView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: WatcherView, context: Context) { view.changed = changed }

    final class WatcherView: NSView {
        var changed: ((Bool) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            guard let window else {
                closed()
                return
            }
            center.addObserver(self, selector: #selector(opened), name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(closed), name: NSWindow.didResignKeyNotification, object: window)
            // macOS places the panel again when the label or the panel
            // changes size.
            center.addObserver(self, selector: #selector(moved), name: NSWindow.didMoveNotification, object: window)
            center.addObserver(self, selector: #selector(moved), name: NSWindow.didResizeNotification, object: window)
            if window.isKeyWindow { opened() }
        }

        @objc private func opened() {
            place()
            changed?(true)
        }

        @objc private func closed() { changed?(false) }

        @objc private func moved() {
            if window?.isVisible == true { place() }
        }

        private func place() {
            guard let window, let item = menuBarItem(for: window), let screen = window.screen else { return }
            let limits = screen.visibleFrame.insetBy(dx: 8, dy: 0)
            let x = max(limits.minX, min(item.maxX - window.frame.width, limits.maxX - window.frame.width))
            if abs(x - window.frame.minX) > 0.5 {
                window.setFrameOrigin(NSPoint(x: x, y: window.frame.minY))
            }
        }

        /// The item's place on the same screen as the panel. If macOS ever
        /// hides it, the panel just stays where macOS put it.
        private func menuBarItem(for window: NSWindow) -> NSRect? {
            guard let screen = window.screen else { return nil }
            return NSApp.windows.first {
                $0.isVisible && $0.className.contains("StatusBarWindow")
                    && $0.frame.midY > screen.visibleFrame.maxY - 1 && screen.frame.intersects($0.frame)
            }?.frame
        }
    }
}
/// In the menu bar panel: rewards today's tomatoes can pay for, to enjoy
/// right after a session ends. Nothing shows until one is affordable;
/// setting rewards up is on the Focus tab.
private struct ReadyRewards: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let repo = app.repo
        let ready = repo.rewardsReady
        if !ready.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ready to enjoy · 🍅 \(repo.tomatoesToSpend) to spend")
                    .font(.subheadline.weight(.semibold))
                ForEach(ready.prefix(3)) { reward in
                    HStack {
                        Text(reward.name).lineLimit(1)
                        Text("\(reward.cost) 🍅").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Enjoy") { withAnimation(.snappy) { repo.spend(on: reward) } }
                            .buttonStyle(.glassProminent)
                            .controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
