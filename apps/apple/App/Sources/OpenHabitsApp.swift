import HabitsCore
import SwiftUI

@main
struct OpenHabitsApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(app.accentName == "system" ? nil : app.accent)
                .onOpenURL { app.open($0) }
        }
        #if os(macOS)
        .defaultSize(width: 1080, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Habit") { app.newHabitRequested = true }
                    .keyboardShortcut("n")
            }
        }
        #endif

        #if os(macOS)
        MenuBarExtra {
            FocusMenu()
                .environment(app)
                .tint(app.accentName == "system" ? nil : app.accent)
        } label: {
            FocusMenuLabel().environment(app)
        }
        .menuBarExtraStyle(.window)

        Settings {
            NavigationStack { SettingsView() }
                .frame(width: 560, height: 680)
                .environment(app)
                .tint(app.accentName == "system" ? nil : app.accent)
        }
        #endif
    }
}

/// The screens in the main navigation.
enum AppTab: Hashable {
    case habits, progress, reflect, focus, settings
}

/// Everything the screens share: the data, sync, the focus timer, and a few
/// bits of navigation state that menus and links can change.
@MainActor
@Observable
final class AppModel {
    let store: LocalStore
    let repo: Repo
    let sync: SyncEngine
    let focus: FocusTimer
    let reminders: Reminders

    var tab: AppTab = .habits
    #if os(macOS)
    /// The Mac window's tab, and the habit shown in Today's preview panel.
    var macTab: MacTab = .today
    var previewHabit: String?
    #endif

    /// The app's accent colour: "system" follows the device (your accent
    /// colour on a Mac, blue on iPhone). Kept per device.
    var accentName = UserDefaults.standard.string(forKey: "accent") ?? "system" {
        didSet { UserDefaults.standard.set(accentName, forKey: "accent") }
    }

    var accent: Color { accentChoices.first { $0.name == accentName }?.color ?? .accentColor }
    /// Set by the New Habit menu command (⌘N).
    var newHabitRequested = false
    /// Shows the setup wizard again, from Settings.
    var replayingSetup = false
    /// A pairing link opened from a QR code, waiting to be used.
    var pendingPairing: Pairing?

    var onboarded: Bool {
        get { store.meta("onboarded") != nil }
        set { store.setMeta("onboarded", newValue ? "1" : nil) }
    }

    init() {
        let folder = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appending(path: "data.sqlite").path
        let store: LocalStore
        do {
            store = try LocalStore(path: path)
        } catch {
            // Never expected; keep the app usable rather than crashing.
            store = try! LocalStore()
        }
        self.store = store
        repo = Repo(store: store)
        sync = SyncEngine(store: store, deviceName: Self.deviceName)
        focus = FocusTimer(repo: repo)
        reminders = Reminders(repo: repo)
        store.onChange = { [weak reminders] in reminders?.refreshSoon() }
        reminders.refreshSoon()
        #if DEBUG
        applyDebugLaunchOptions()
        #endif
        sync.start()
    }

    private static var deviceName: String {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }

    /// Starts a pomodoro for a habit and shows the timer.
    func focus(on habit: Habit) {
        if focus.running || focus.paused {
            focus.habitId = habit.id
        } else {
            focus.select(.focus)
            focus.habitId = habit.id
            focus.start()
        }
        #if os(macOS)
        macTab = .focus
        #else
        tab = .focus
        #endif
    }

    /// Handles `tasks://pair?…` links, e.g. from scanning a pairing QR code
    /// with the Camera app.
    func open(_ url: URL) {
        if let pairing = Pairing(payload: url.absoluteString) { pendingPairing = pairing }
    }
}
