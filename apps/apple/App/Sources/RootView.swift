import HabitsCore
import SwiftUI

/// Shows the setup wizard until it's been finished on this device, then the
/// app.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var phase

    var body: some View {
        @Bindable var app = app
        Group {
            if app.onboarded {
                #if os(macOS)
                MacMainView()
                #else
                MainView()
                #endif
            } else {
                OnboardingView(replay: false)
            }
        }
        .sheet(isPresented: $app.replayingSetup) {
            OnboardingView(replay: true)
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 640)
                #endif
        }
        .sheet(item: $app.pendingPairing) { pairing in
            PairingLinkView(pairing: pairing)
        }
        // A new day may have started while the app was away.
        .onChange(of: phase) { _, now in
            if now == .active { app.reminders.refreshSoon() }
        }
    }
}

extension Pairing: @retroactive Identifiable {
    public var id: String { code }
}

struct MainView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.tab) {
            Tab("Habits", systemImage: "checklist", value: AppTab.habits) {
                NavigationStack { HabitsView() }
            }
            Tab("Progress", systemImage: "square.grid.3x3", value: AppTab.progress) {
                NavigationStack { ProgressScreen() }
            }
            Tab("Reflect", systemImage: "text.book.closed", value: AppTab.reflect) {
                NavigationStack { ReflectView() }
            }
            Tab("Focus", systemImage: "timer", value: AppTab.focus) {
                NavigationStack { FocusView() }
            }
            #if os(iOS)
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack { SettingsView() }
            }
            #endif
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

/// Opened from a pairing link (e.g. a QR code scanned with the Camera app):
/// signs this device in with one tap.
struct PairingLinkView: View {
    let pairing: Pairing
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("Connect to your server?")
                    .font(.title2.bold())
                if let warning = app.sync.replacementWarning(for: pairing.server) {
                    // Already signed in elsewhere: say what switching costs.
                    Text(warning)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.orange)
                } else {
                    Text("This signs this device in to \(pairing.server), so your habits stay in sync with your other devices.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                Button {
                    Task { await connect() }
                } label: {
                    Text(working ? "Connecting…"
                        : app.sync.replacementWarning(for: pairing.server) == nil ? "Connect" : "Switch Servers")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(working)
            }
            .padding(28)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func connect() async {
        working = true
        defer { working = false }
        do {
            try await app.sync.redeem(pairing)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
