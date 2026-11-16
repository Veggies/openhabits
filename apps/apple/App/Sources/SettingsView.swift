import CoreImage.CIFilterBuiltins
import HabitsCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var connecting = false
    @State private var addingDevice = false
    @State private var changingPassword = false

    var body: some View {
        let sync = app.sync
        let repo = app.repo
        let account = sync.account
        let signedIn = sync.isConfigured && account != nil

        Form {
            Section {
                if signedIn, let account {
                    Label {
                        Text("Signed in as \(account.username)")
                    } icon: {
                        Image(systemName: "person.crop.circle.fill")
                            .foregroundStyle(.tint)
                    }
                    SyncStatusRow()
                    Button("Add a Device", systemImage: "qrcode") { addingDevice = true }
                    Button("Change Password", systemImage: "key") { changingPassword = true }
                    if account.isOwner {
                        NavigationLink {
                            PeopleView()
                        } label: {
                            Label("People", systemImage: "person.2")
                        }
                        if let page = sync.setupPageUrl.flatMap(URL.init(string:)) {
                            Link(destination: page) {
                                Label("Server Settings", systemImage: "server.rack")
                            }
                        }
                    }
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        Task { await sync.signOut() }
                    }
                } else {
                    Text(sync.status == .signedOut
                        ? "You were signed out. Sign in again to keep syncing."
                        : "Everything works on this device as it is. If you'd like your other devices to stay in sync, connect to your server.")
                        .foregroundStyle(.secondary)
                    Button("Connect to Your Server", systemImage: "server.rack") { connecting = true }
                }
            } header: {
                Text("Your server")
            } footer: {
                if signedIn && sync.store.pendingCount > 0 {
                    Text("\(sync.store.pendingCount) change\(sync.store.pendingCount == 1 ? "" : "s") waiting to upload")
                }
            }

            Section {
                Picker("Week starts on", selection: Binding(get: { repo.weekStart }, set: { repo.setPrefs(["weekStart": .int($0)]) })) {
                    Text("Sunday").tag(Days.sunday)
                    Text("Monday").tag(Days.monday)
                }
                NavigationLink {
                    CalendarLinkView()
                } label: {
                    Label {
                        Text("Show Habits in Your Calendar App")
                        Text(signedIn ? "Habits with a time show up in Apple, Google or Outlook Calendar."
                            : "Connect to your server first, above.")
                    } icon: {
                        Image(systemName: "calendar.badge.plus")
                    }
                }
                .disabled(!signedIn)
            } header: {
                Text("Habits")
            }

            RemindersSection()

            Section {
                AccentPicker()
            } header: {
                Text("Appearance")
            } footer: {
                Text("System uses your device's accent colour\(isMac ? ", from System Settings → Appearance" : "")")
            }

            Section {
                Button("Show the Tour Again", systemImage: "sparkles") { app.replayingSetup = true }
            } footer: {
                Text("A quick look at everything OpenHabits can do, with the option to build a habit step by step.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .largeTitle()
        .sheet(isPresented: $connecting) {
            NavigationStack {
                ConnectView { _ in connecting = false }
                    .navigationTitle("Connect")
                    .inlineTitle()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { connecting = false } }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 520)
            #endif
        }
        .sheet(isPresented: $addingDevice) { AddDeviceView() }
        .sheet(isPresented: $changingPassword) { ChangePasswordView() }
    }
}

struct SyncStatusRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let sync = app.sync
        HStack {
            switch sync.status {
            case .syncing:
                Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
            case .error:
                Label {
                    Text("Couldn't sync just now")
                    Text(sync.lastError ?? "")
                } icon: {
                    Image(systemName: "exclamationmark.icloud").foregroundStyle(.red)
                }
            default:
                Label {
                    Text(sync.lastSynced.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Connected")
                } icon: {
                    Image(systemName: "checkmark.icloud").foregroundStyle(.green)
                }
            }
            Spacer()
            Button("Sync Now") { Task { await sync.syncNow() } }
                .buttonStyle(.borderless)
                .disabled(sync.status == .syncing)
        }
    }
}

/// A QR code for signing another device in, and the same as text for a
/// computer.
struct AddDeviceView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var result: Result<(code: String, pairing: Pairing), Error>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    switch result {
                    case nil:
                        ProgressView().frame(height: 260)
                    case .failure(let error):
                        Text(error.localizedDescription).foregroundStyle(.secondary)
                    case .success(let data):
                        Text("On your phone, open the Camera app and point it at this code:")
                            .multilineTextAlignment(.center)
                        if let image = qrImage(data.pairing.payload) {
                            Image(decorative: image, scale: 1)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 220, height: 220)
                                .padding(12)
                                .background(.white, in: .rect(cornerRadius: 16))
                        }
                        Text("On a computer, enter the server address and this code:")
                            .multilineTextAlignment(.center)
                        VStack(spacing: 4) {
                            Text(data.pairing.server).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(data.code)
                                .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                                .textSelection(.enabled)
                        }
                        Text("This code works once and expires in 10 minutes.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Add a Device")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                do { result = .success(try await app.sync.pairingCode()) }
                catch { result = .failure(error) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }

    private func qrImage(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

struct ChangePasswordView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                SecureField("Current password", text: $current)
                Section {
                    SecureField("New password", text: $new)
                } footer: {
                    Text(error ?? "At least 8 characters.")
                        .foregroundStyle(error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Change Password")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Change") {
                        Task {
                            working = true
                            defer { working = false }
                            do {
                                try await app.sync.changePassword(current: current, new: new)
                                dismiss()
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                    .disabled(current.isEmpty || new.count < 8 || working)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 260)
        #endif
    }
}

/// Everyone with an account on the server. Only the owner sees this.
struct PeopleView: View {
    @Environment(AppModel.self) private var app
    @State private var people: Result<[Account], Error>?
    @State private var adding = false
    @State private var removing: Account?
    @State private var problem: String?

    var body: some View {
        Form {
            switch people {
            case nil:
                ProgressView()
            case .failure(let error):
                Text(error.localizedDescription).foregroundStyle(.secondary)
            case .success(let list):
                Section {
                    ForEach(list) { person in
                        LabeledContent {
                            if !person.isOwner {
                                Button("Remove", role: .destructive) { removing = person }
                                    .buttonStyle(.borderless)
                            }
                        } label: {
                            Text(person.username)
                            if person.isOwner { Text("Owner") }
                        }
                    }
                } footer: {
                    Text("Everyone gets their own private habits.")
                }
            }
            Section {
                Button("Add a Person", systemImage: "person.badge.plus") { adding = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("People")
        .task { await load() }
        .sheet(isPresented: $adding, onDismiss: { Task { await load() } }) { AddPersonView() }
        .confirmationDialog("Remove \(removing?.username ?? "")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                guard let person = removing else { return }
                Task {
                    do { try await app.sync.removePerson(person.id) } catch { problem = error.localizedDescription }
                    await load()
                }
            }
        } message: {
            Text("This deletes their account and everything they've saved on this server.")
        }
        .alert("Couldn't remove them", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") {}
        } message: {
            Text(problem ?? "")
        }
    }

    private func load() async {
        do { people = .success(try await app.sync.people()) }
        catch { people = .failure(error) }
    }
}

struct AddPersonView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Username", text: $username).plainEntry()
                Section {
                    SecureField("Password", text: $password)
                } footer: {
                    Text(error ?? "At least 8 characters.")
                        .foregroundStyle(error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add a Person")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            do {
                                try await app.sync.addPerson(username: username.trimmingCharacters(in: .whitespaces),
                                    password: password)
                                dismiss()
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.count < 8)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 320)
        #endif
    }
}

/// The private link that shows habits in a calendar app.
struct CalendarLinkView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var link: Result<(url: String, anywhere: Bool), Error>?
    @State private var confirmingNew = false
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Text("Any habit with a time shows up in your calendar as a repeating event, on the days it's scheduled. When you change a habit here, your calendar catches up within an hour or so.")
            }
            switch link {
            case nil:
                ProgressView()
            case .failure(let error):
                Text("Couldn't get your link: \(error.localizedDescription)")
            case .success(let link):
                Section {
                    Text(link.url)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    Button(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        copy(link.url)
                        copied = true
                    }
                    Button("Open in Calendar", systemImage: "calendar") {
                        if let url = URL(string: link.url.replacingOccurrences(
                            of: "^https?", with: "webcal", options: .regularExpression))
                        {
                            openURL(url)
                        }
                    }
                } footer: {
                    if !link.anywhere {
                        Text("Right now this link only works on your home network, so it won't work in Google Calendar or when you're out. Calendar apps need an address with a normal certificate, so on your server's setup page, add a reverse proxy address under Advanced.")
                            .foregroundStyle(.orange)
                    }
                }
                Section("How to add it elsewhere") {
                    Text("**Google Calendar:** on the website, next to \"Other calendars\", choose + → From URL and paste the link.")
                    Text("**Outlook:** choose Add calendar → Subscribe from web and paste the link.")
                }
                Section {
                    Button("Make a New Link", role: .destructive) { confirmingNew = true }
                } footer: {
                    Text("Anyone with this link can see your habits' names and times, so keep it to yourself. If it's ever shared by mistake, make a new one.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Calendar App")
        .inlineTitle()
        .task { await load() }
        .confirmationDialog("Make a new link?", isPresented: $confirmingNew, titleVisibility: .visible) {
            Button("Make a New Link", role: .destructive) { Task { await load(replace: true) } }
        } message: {
            Text("The current link will stop working, so any calendar using it will stop showing your habits until you add the new one.")
        }
    }

    private func load(replace: Bool = false) async {
        do { link = .success(try await app.sync.calendarLink(replace: replace)) }
        catch { link = .failure(error) }
        copied = false
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

#if os(macOS)
private let isMac = true
#else
private let isMac = false
#endif

/// Choose the app's accent colour, as swatches.
struct AccentPicker: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Accent colour")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(accentChoices, id: \.name) { choice in
                    let selected = app.accentName == choice.name
                    Button {
                        app.accentName = choice.name
                    } label: {
                        Group {
                            if choice.name == "system" {
                                // A multicolour swatch, as macOS uses for "follow the system".
                                Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red],
                                    center: .center))
                            } else {
                                Circle().fill(choice.color)
                            }
                        }
                        .frame(width: 26, height: 26)
                        .overlay {
                            if selected {
                                Circle().strokeBorder(.background, lineWidth: 2.5)
                                Circle().strokeBorder(.primary.opacity(0.4), lineWidth: 1)
                            }
                        }
                        .padding(3)
                        .overlay {
                            if selected { Circle().strokeBorder(.secondary, lineWidth: 1.5) }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(choice.label)
                    .accessibilityLabel(choice.label)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Which reminders this device sends.
struct RemindersSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var reminders = app.reminders
        Section {
            Toggle(isOn: $reminders.habitTimes) {
                Text("At each habit's time")
                Text("For habits with a set time. You can mark it done right from the reminder.")
            }
            Toggle(isOn: $reminders.checkIn.animation()) {
                Text("Daily check-in")
                Text("Lists the habits you haven't marked yet that day. It stays quiet once everything's done.")
            }
            if reminders.checkIn {
                DatePicker("Check-in time", selection: $reminders.checkInTime, displayedComponents: .hourAndMinute)
            }
            if reminders.denied {
                Text("Notifications are turned off for OpenHabits. To get reminders, turn them on in your device's Settings → Notifications → OpenHabits.")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Reminders")
        } footer: {
            Text("Reminders are set on this device only, so you can have them on your phone but not your computer.")
        }
    }
}
