import CryptoKit
import Foundation
import Observation

public enum SyncStatus: Sendable { case notConfigured, idle, syncing, error, signedOut }

/// What a server says about itself before you sign in.
public struct ServerInfo: Sendable {
    public let url: String
    public let name: String
    /// Label for the single sign-on button, e.g. "Google", if offered.
    public let oidcLabel: String?
}

public struct Account: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let username: String
    public let email: String?
    public let isOwner: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        username = try c.decode(String.self, forKey: .username)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        isOwner = try c.decodeIfPresent(Bool.self, forKey: .isOwner) ?? false
    }
}

/// Something the person should read, worded for them.
public struct SyncError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The server uses its own certificate and this device doesn't trust it
/// yet. Show `shortCode` so the person can compare it with the security
/// code on the server's setup page.
public struct UntrustedServer: LocalizedError, Sendable {
    public let url: String
    public let fingerprint: String
    public var shortCode: String { fingerprint.split(separator: ":").prefix(8).joined(separator: ":") }
    public var errorDescription: String? { "This server's security code isn't trusted yet." }
}

/// A pairing QR code: `openhabits://pair?server=…&code=…&remote=…&fp=…`.
public struct Pairing: Sendable {
    public let server: String
    public let code: String
    public let remote: String?
    public let fingerprint: String?

    public init(server: String, code: String, remote: String?, fingerprint: String?) {
        self.server = server
        self.code = code
        self.remote = remote
        self.fingerprint = fingerprint
    }

    public init?(payload: String) {
        guard let c = URLComponents(string: payload), c.scheme == "openhabits", c.host == "pair",
            let server = c.queryItems?.first(where: { $0.name == "server" })?.value,
            let code = c.queryItems?.first(where: { $0.name == "code" })?.value
        else { return nil }
        self.server = server
        self.code = code
        remote = c.queryItems?.first(where: { $0.name == "remote" })?.value
        fingerprint = c.queryItems?.first(where: { $0.name == "fp" })?.value
    }

    public var payload: String {
        var c = URLComponents()
        c.scheme = "openhabits"
        c.host = "pair"
        c.queryItems = [URLQueryItem(name: "server", value: server), URLQueryItem(name: "code", value: code)]
            + (remote.map { [URLQueryItem(name: "remote", value: $0)] } ?? [])
            + (fingerprint.map { [URLQueryItem(name: "fp", value: $0)] } ?? [])
        return c.string ?? ""
    }
}

/// Signs in to the server and keeps the `LocalStore` in step with it:
/// sends queued edits and fetches everything new, shortly after each edit
/// and every 30 seconds. Matches apps/client/lib/data/sync_engine.dart.
///
/// A device knows up to two addresses for its server: the one it signed in
/// with (usually the home network) and a remote one for when it's away.
/// Requests try the one that last worked first, then the others.
@MainActor
@Observable
public final class SyncEngine {
    public let store: LocalStore
    public let deviceName: String

    public private(set) var status: SyncStatus = .notConfigured
    public private(set) var lastError: String?
    public private(set) var lastSynced: Date?

    @ObservationIgnored private let pinning = PinningDelegate()
    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config, delegate: pinning, delegateQueue: nil)
    }()
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var again = false
    @ObservationIgnored private var activeUrl: String?

    public init(store: LocalStore, deviceName: String) {
        self.store = store
        self.deviceName = deviceName
        pinning.pinned = store.meta("fingerprint")
        if isConfigured { status = .idle }
        store.onLocalWrite = { [weak self] in self?.localChange() }
    }

    public var serverUrl: String? { store.meta("serverUrl") }
    public var remoteUrl: String? { store.meta("remoteUrl") }
    private var token: String? { store.meta("token") }

    public var isConfigured: Bool {
        !(serverUrl ?? "").isEmpty && !(token ?? "").isEmpty
    }

    public var account: Account? {
        store.meta("account").flatMap { try? JSONDecoder().decode(Account.self, from: Data($0.utf8)) }
    }

    /// The server's own settings page.
    public var setupPageUrl: String? { activeUrl ?? serverUrl }

    public func start() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Accepts "habits.example.com", "192.168.1.10:8080" or a full URL. Home
    /// network addresses and anything with a port default to http.
    public nonisolated static func normalize(_ input: String) -> String {
        var url = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        if !url.contains("://") {
            let local =
                url.range(of: #"^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)"#,
                    options: .regularExpression) != nil
                || url.range(of: #":\d+$"#, options: .regularExpression) != nil
            url = (local ? "http://" : "https://") + url
        }
        return url
    }

    /// Looks a server up before signing in. Throws `UntrustedServer` for a
    /// server with its own certificate that this device doesn't know.
    public func serverInfo(_ input: String) async throws -> ServerInfo {
        let url = Self.normalize(input)
        guard let endpoint = URL(string: url + "/auth/info") else {
            throw SyncError("That doesn't look like a server address.")
        }
        pinning.lastSeen = nil
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 10
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if let fp = pinning.lastSeen { throw UntrustedServer(url: url, fingerprint: fp) }
            throw SyncError("Couldn't reach \(url). Check the address and that the server is running.")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
            let json = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else {
            throw SyncError("\(url) doesn't look like an OpenHabits server (error \(code)).")
        }
        return ServerInfo(url: url, name: json["name"]?.string ?? "OpenHabits",
            oidcLabel: json["oidc"]?.object?["label"]?.string)
    }

    /// Trusts a certificate the person confirmed, for signing in.
    public func trustCertificate(_ fingerprint: String) { pinning.trustOnce = fingerprint }

    @discardableResult
    public func signIn(url: String, username: String, password: String) async throws -> Account {
        try await finishSignIn(urls: [url], path: "/auth/login",
            body: ["username": .string(username), "password": .string(password)])
    }

    /// Signs in with a one-time code from another device. A QR code also
    /// carries the remote address and certificate, so the device works away
    /// from home straight away.
    @discardableResult
    public func redeem(url: String, code: String, remoteUrl: String? = nil, fingerprint: String? = nil)
        async throws -> Account
    {
        if let fingerprint { pinning.trustOnce = fingerprint }
        return try await finishSignIn(urls: [url] + (remoteUrl.map { [$0] } ?? []),
            path: "/auth/redeem", body: ["code": .string(code)])
    }

    /// Where to send the browser for single sign-on. The server sends it
    /// back to `openhabits://auth?code=…`; pass that code to `redeem`.
    public func oidcStartURL(_ url: String) -> URL? {
        var c = URLComponents(string: url + "/auth/oidc/start")
        c?.queryItems = [URLQueryItem(name: "redirect_uri", value: "openhabits://auth")]
        return c?.url
    }

    private func finishSignIn(urls: [String], path: String, body: Fields) async throws -> Account {
        var all = body
        all["device"] = .string(deviceName)
        let (url, response) = try await sendFirst(urls: urls, method: "POST", path: path, body: all, auth: false)
        guard let user = response["user"], let tokenValue = response["token"]?.string,
            let account = try? JSONDecoder().decode(Account.self, from: JSONEncoder().encode(user))
        else { throw SyncError("The server sent back something unexpected. Try again.") }
        // A different person on this device: don't mix their data with the
        // previous person's. Data made before any sign-in is kept.
        if let previous = self.account, previous.id != account.id { store.reset() }
        if urls.first != serverUrl {
            store.setMeta("cursor", "0")
            store.setMeta("remoteUrl", nil)
            store.setMeta("fingerprint", nil)
            store.setMeta("directoryLookup", nil)
        }
        store.setMeta("serverUrl", urls.first)
        store.setMeta("token", tokenValue)
        store.setMeta("account", user.encoded())
        if urls.count > 1 { store.setMeta("remoteUrl", urls[1]) }
        if let trusted = pinning.trustOnce {
            store.setMeta("fingerprint", trusted)
            pinning.pinned = trusted
        }
        pinning.trustOnce = nil
        activeUrl = url
        status = .idle
        Task { await syncNow() }
        return account
    }

    /// Signs out. Data stays on the device until someone else signs in.
    public func signOut() async {
        if isConfigured { _ = try? await post("/auth/logout", [:]) }
        store.setMeta("token", nil)
        status = .notConfigured
    }

    /// A one-time code for adding another device, as a pairing QR payload.
    public func pairingCode() async throws -> (code: String, pairing: Pairing) {
        let b = try await post("/auth/pairing-code", [:])
        let code = b["code"]?.string ?? ""
        return (code, Pairing(server: serverUrl ?? "", code: code,
            remote: b["remoteUrl"]?.string, fingerprint: b["fingerprint"]?.string))
    }

    /// The private link that shows this person's habits in a calendar app.
    /// `anywhere` is false when the server has no public address.
    public func calendarLink(replace: Bool = false) async throws -> (url: String, anywhere: Bool) {
        let b = replace ? try await post("/calendar-link/reset", [:]) : try await send("GET", "/calendar-link")
        return (b["url"]?.string ?? "", b["anywhere"]?.bool == true)
    }

    public func people() async throws -> [Account] {
        let b = try await send("GET", "/users")
        return (b["users"]?.array ?? []).compactMap {
            try? JSONDecoder().decode(Account.self, from: JSONEncoder().encode($0))
        }
    }

    public func addPerson(username: String, password: String, email: String = "") async throws {
        _ = try await post("/users", [
            "username": .string(username), "password": .string(password), "email": .string(email),
        ])
    }

    public func removePerson(_ id: String) async throws { _ = try await send("DELETE", "/users/\(id)") }

    public func changePassword(current: String, new: String) async throws {
        _ = try await post("/auth/password", ["current": .string(current), "new": .string(new)])
    }

    public func setEmail(_ email: String) async throws {
        let b = try await post("/auth/email", ["email": .string(email)])
        if let user = b["user"] { store.setMeta("account", user.encoded()) }
    }

    // MARK: Requests

    private func localChange() {
        guard isConfigured else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            if !Task.isCancelled { await self?.syncNow() }
        }
    }

    private func post(_ path: String, _ body: Fields) async throws -> Fields {
        try await send("POST", path, body: body)
    }

    private func send(_ method: String, _ path: String, body: Fields? = nil) async throws -> Fields {
        var urls: [String] = []
        for u in [activeUrl, serverUrl, remoteUrl] { if let u, !urls.contains(u) { urls.append(u) } }
        let (url, result) = try await sendFirst(urls: urls, method: method, path: path, body: body)
        activeUrl = url
        return result
    }

    private struct Unreachable: Error { var timedOut = false }

    /// Tries each address in turn. Only connection failures move on to the
    /// next; a real answer from the server, even an error, is final.
    private func sendFirst(urls: [String], method: String, path: String, body: Fields?, auth: Bool = true,
        askDirectory: Bool = true) async throws -> (String, Fields)
    {
        var timedOut = false
        for url in urls {
            do {
                return (url, try await sendTo(url + path, method: method, body: body, auth: auth,
                    quick: urls.count > 1))
            } catch let e as Unreachable {
                timedOut = e.timedOut
            }
        }
        // None of the known addresses answer. The home's internet address
        // may have changed while this device was away: ask the directory
        // where the server is now. The certificate is still checked, so a
        // wrong answer can't lead anywhere else.
        if askDirectory {
            let moved = await directoryUrls().filter { !urls.contains($0) }
            if !moved.isEmpty,
                let found = try? await sendFirst(urls: moved, method: method, path: path, body: body,
                    auth: auth, askDirectory: false)
            {
                store.setMeta("remoteUrl", found.0)
                return found
            }
        }
        throw SyncError(timedOut
            ? "The server's taking too long to answer. Make sure it's running, then try again."
            : "Couldn't reach your server. Check that it's running and that you're online.")
    }

    private func sendTo(_ address: String, method: String, body: Fields?, auth: Bool, quick: Bool)
        async throws -> Fields
    {
        guard let url = URL(string: address) else { throw Unreachable() }
        var request = URLRequest(url: url)
        request.httpMethod = method
        // With another address to fall back on, don't wait long for this one.
        request.timeoutInterval = quick ? 6 : 30
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if auth, let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Unreachable(timedOut: error.code == .timedOut)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try? JSONDecoder().decode(Fields.self, from: data)
        if code == 401 && auth && isConfigured {
            // The session was ended elsewhere, or the account was removed.
            store.setMeta("token", nil)
            status = .signedOut
        }
        guard code == 200 else {
            throw SyncError(decoded?["error"]?.string
                ?? "Something went wrong on the server (error \(code)). Try again in a little while.")
        }
        return decoded ?? [:]
    }

    // MARK: Sync

    /// Syncs now. If a sync is already running, another pass is queued.
    public func syncNow() async {
        guard isConfigured else { return }
        if let running = inFlight {
            again = true
            await running.value
            return
        }
        let task = Task { await self.sync() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func sync() async {
        status = .syncing
        do {
            repeat {
                again = false
                try await roundTrip()
            } while again || store.pendingCount > 0
            status = .idle
            lastError = nil
            lastSynced = Date()
        } catch {
            if status != .signedOut { status = .error }
            lastError = error.localizedDescription
        }
    }

    private func roundTrip() async throws {
        let pending = store.pending()
        let changes = try JSONDecoder().decode([JSONValue].self, from: JSONEncoder().encode(pending.changes))
        let body = try await post("/sync", ["since": .int(store.cursor), "changes": .array(changes)])
        if pending.lastId > 0 { store.markSent(upTo: pending.lastId) }
        followRemote(body["server"])
        let incoming = try JSONDecoder().decode([Change].self,
            from: JSONEncoder().encode(body["changes"] ?? .array([])))
        try store.applyRemote(incoming, cursor: body["cursor"]?.int ?? store.cursor)
    }

    /// Where the directory says this server can be reached now.
    private func directoryUrls() async -> [String] {
        guard let lookup = store.meta("directoryLookup"), let url = URL(string: lookup) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let json = try? JSONDecoder().decode([String: JSONValue].self, from: data),
            let urls = json["urls"]?.array
        else { return [] }
        return urls.compactMap(\.string).filter { $0.hasPrefix("https://") }
    }

    /// Keeps the remote address current, e.g. after the home internet
    /// address changes or remote access is turned on or off.
    private func followRemote(_ server: JSONValue?) {
        guard let server = server?.object else { return }
        if let directory = server["directory"] {
            store.setMeta("directoryLookup", directory.object?["lookup"]?.string)
        }
        if let remote = server["remote"]?.object, let url = remote["url"]?.string {
            store.setMeta("remoteUrl", url)
            if let fp = remote["fingerprint"]?.string {
                store.setMeta("fingerprint", fp)
                pinning.pinned = fp
            }
        } else if server["remoteEnabled"]?.bool == false {
            store.setMeta("remoteUrl", nil)
        }
    }
}

/// Accepts normal, valid certificates as usual, plus the server's own
/// certificate when its fingerprint matches the one this device pinned.
final class PinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _pinned: String?
    private var _trustOnce: String?
    private var _lastSeen: String?

    var pinned: String? {
        get { lock.withLock { _pinned } }
        set { lock.withLock { _pinned = newValue } }
    }
    var trustOnce: String? {
        get { lock.withLock { _trustOnce } }
        set { lock.withLock { _trustOnce = newValue } }
    }
    var lastSeen: String? {
        get { lock.withLock { _lastSeen } }
        set { lock.withLock { _lastSeen = newValue } }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }
        if SecTrustEvaluateWithError(trust, nil) { return (.performDefaultHandling, nil) }
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return (.cancelAuthenticationChallenge, nil)
        }
        let der = SecCertificateCopyData(leaf) as Data
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        lastSeen = fingerprint
        if fingerprint == pinned || fingerprint == trustOnce {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.cancelAuthenticationChallenge, nil)
    }
}
