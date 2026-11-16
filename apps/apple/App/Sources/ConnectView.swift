import AuthenticationServices
import HabitsCore
import SwiftUI
#if os(iOS)
import VisionKit
#endif

/// Connects this device to a server: the address first, then any way of
/// signing in that the server offers.
struct ConnectView: View {
    let onSignedIn: (Account) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var address = ""
    @State private var server: ServerInfo?
    @State private var username = ""
    @State private var password = ""
    @State private var code = ""
    @State private var useCode = false
    @State private var working = false
    @State private var error: String?
    @State private var untrusted: UntrustedServer?
    @State private var scanning = false
    /// A scanned pairing code, waiting for the person to confirm where it
    /// leads.
    @State private var scanned: Pairing?

    var body: some View {
        Form {
            if let server {
                Section {
                    LabeledContent("Server") {
                        Button(server.url) { self.server = nil }
                            .buttonStyle(.borderless)
                    }
                }
                if useCode {
                    Section {
                        TextField("Pairing code, e.g. ABCD-1234", text: $code).plainEntry()
                    } footer: {
                        Text("On a device that's already signed in, go to Settings → Add a Device.")
                    }
                    Section {
                        Button("Connect") { run { try await app.sync.redeem(url: server.url, code: code) } }
                            .disabled(code.isEmpty || working)
                    }
                } else {
                    Section("Sign in to \(server.name)") {
                        TextField("Username", text: $username)
                            .plainEntry()
                            .textContentType(.username)
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .onSubmit(signIn)
                    }
                    Section {
                        Button("Sign In", action: signIn)
                            .disabled(username.isEmpty || password.isEmpty || working)
                        if let label = server.oidcLabel {
                            Button("Sign In with \(label)") { signInWithSSO(server) }
                                .disabled(working)
                        }
                    }
                }
                Section {
                    Button(useCode ? "Use a username and password instead" : "Have a code from another device?") {
                        useCode.toggle()
                    }
                    .buttonStyle(.borderless)
                    .font(.footnote)
                }
            } else {
                #if os(iOS)
                Section {
                    Button("Scan the Code from Another Device", systemImage: "qrcode.viewfinder") { scanning = true }
                } footer: {
                    Text("On a device that's already signed in, go to Settings → Add a Device.")
                }
                #endif
                Section {
                    TextField("Server address", text: $address, prompt: Text("habits.example.com or 192.168.1.10:8080"))
                        .plainEntry()
                        #if os(iOS)
                        .keyboardType(.URL)
                        #endif
                        .onSubmit(lookUp)
                } header: {
                    Text("Your server's address")
                }
                Section {
                    Button("Continue", action: lookUp)
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || working)
                }
            }
            if working {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .onAppear { if address.isEmpty { address = app.sync.serverUrl ?? "" } }
        .alert("Connect to \(scanned?.server ?? "this server")?",
            isPresented: Binding(get: { scanned != nil }, set: { if !$0 { scanned = nil } }),
            presenting: scanned
        ) { pairing in
            Button("Cancel", role: .cancel) {}
            Button(app.sync.replacementWarning(for: pairing.server) == nil ? "Connect" : "Switch Servers") {
                run {
                    try await app.sync.redeem(url: SyncEngine.normalize(pairing.server), code: pairing.code,
                        remoteUrl: pairing.remote, fingerprint: pairing.fingerprint)
                }
            }
        } message: { pairing in
            Text(app.sync.replacementWarning(for: pairing.server)
                ?? "This signs this device in to that server, so your habits stay in sync with your other devices.")
        }
        .alert("Check the security code", isPresented: Binding(get: { untrusted != nil }, set: { if !$0 { untrusted = nil } }),
            presenting: untrusted
        ) { u in
            Button("Cancel", role: .cancel) {}
            Button("It Matches") {
                app.sync.trustCertificate(u.fingerprint, for: u.url)
                lookUp(u.url)
            }
        } message: { u in
            Text("On your server's setup page, under Remote access, find the security code. Make sure it matches this one:\n\n\(u.shortCode)\n\nIf it doesn't match, don't continue: you may not be connected to your own server.")
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $scanning) {
            QRScanner { text in
                scanning = false
                guard let pairing = Pairing(payload: text) else {
                    error = "That QR code isn't an OpenHabits pairing code."
                    return
                }
                scanned = pairing
            } onCancel: {
                scanning = false
            }
        }
        #endif
    }

    private func lookUp() { lookUp(address) }

    private func lookUp(_ input: String) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                server = try await app.sync.serverInfo(input)
            } catch let e as UntrustedServer {
                untrusted = e
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func signIn() {
        guard let server else { return }
        run { try await app.sync.signIn(url: server.url, username: username.trimmingCharacters(in: .whitespaces), password: password) }
    }

    private func signInWithSSO(_ server: ServerInfo) {
        guard let start = app.sync.oidcStartURL(server.url) else { return }
        run {
            let callback = try await webAuth.authenticate(using: start, callbackURLScheme: "openhabits",
                preferredBrowserSession: .shared)
            guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value
            else { throw SyncError("Sign-in was cancelled.") }
            return try await app.sync.redeem(url: server.url, code: code)
        }
    }

    private func run(_ action: @escaping () async throws -> Account) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                onSignedIn(try await action())
            } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
                // Closed the sign-in window: nothing to say.
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

#if os(iOS)
/// Scans a pairing QR code with the camera.
struct QRScanner: View {
    let onFound: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    Scanner(onFound: onFound)
                        .ignoresSafeArea()
                        .overlay(alignment: .bottom) {
                            Text("Point your camera at the code on your other device.")
                                .padding()
                                .glassEffect()
                                .padding(.bottom, 40)
                        }
                } else {
                    ContentUnavailableView("Can't use the camera", systemImage: "camera",
                        description: Text("Enter your server's address and a pairing code instead."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
            }
        }
    }

    private struct Scanner: UIViewControllerRepresentable {
        let onFound: (String) -> Void

        func makeUIViewController(context: Context) -> DataScannerViewController {
            let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                isHighlightingEnabled: true)
            scanner.delegate = context.coordinator
            try? scanner.startScanning()
            return scanner
        }

        func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

        func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

        final class Coordinator: NSObject, DataScannerViewControllerDelegate {
            let onFound: (String) -> Void
            var done = false
            init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

            func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem],
                allItems: [RecognizedItem])
            {
                for case .barcode(let code) in items {
                    if let text = code.payloadStringValue, !done {
                        done = true
                        onFound(text)
                    }
                }
            }
        }
    }
}
#endif
