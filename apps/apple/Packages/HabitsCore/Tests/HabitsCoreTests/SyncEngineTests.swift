import Foundation
import Testing

@testable import HabitsCore

@Suite struct SharedFixtures {
    @Test func clockAndMergeMatchDart() throws {
        let f = try fixture("hlc.json")
        func hlc(_ v: JSONValue) -> HLC { HLC.parse(v.string!)! }
        for c in f["compare"]!.array! {
            let a = hlc(c.array![0]), b = hlc(c.array![1]), expected = c.array![2].int!
            let actual = a < b ? -1 : (b < a ? 1 : 0)
            #expect(actual == expected, "\(a) vs \(b)")
        }
        for c in f["send"]!.array! {
            #expect(hlc(c.array![0]).send(c.array![1].int!).pack() == c.array![2].string)
        }
        for c in f["receive"]!.array! {
            let got = hlc(c.array![0]).receive(hlc(c.array![1]), c.array![2].int!)
            #expect(got.pack() == c.array![3].string, "\(c)")
        }
        for c in f["shouldApply"]!.array! {
            let current: HLC? = c.array![1] == .null ? nil : hlc(c.array![1])
            #expect(shouldApply(hlc(c.array![0]), over: current) == c.array![2].bool, "\(c)")
        }
    }

    @Test func directoryRecordSignedByTheDartServer() throws {
        let f = try fixture("directory_record.json")
        let key = f["key"]!.string!, id = f["id"]!.string!
        let answer: [String: JSONValue] = [
            "urls": .array([.string("https://evil.example")]),  // unsigned, ignored
            "payload": f["payload"]!, "sig": f["sig"]!,
        ]
        #expect(DirectoryRecord.verify(answer, key: key, id: id)?.urls == ["https://203.0.113.7:8443"])
        #expect(DirectoryRecord.verify(answer, key: key, id: "someone-else") == nil)
        var tampered = answer
        tampered["payload"] = .string(f["payload"]!.string!.replacingOccurrences(of: "203.0.113.7", with: "198.51.100.66"))
        #expect(DirectoryRecord.verify(tampered, key: key, id: id) == nil)
        #expect(DirectoryRecord.verify(answer, key: key, id: id, notBefore: Int.max) == nil)
    }
}

@Suite @MainActor struct FutureDates {
    @Test func aFieldWrittenByADeviceWithItsDateAheadCanStillBeChanged() throws {
        let store = try LocalStore()
        let ahead = Int(Date().timeIntervalSince1970 * 1000) + 3 * 24 * 3600 * 1000
        try store.applyRemote([
            Change(table: "habits", rowId: "h1", field: "name", value: "From the future",
                hlc: HLC(ahead, 0, "wrong-date"))
        ], cursor: 1)
        store.write("habits", "h1", ["name": "Read before bed"])
        #expect(store.row("habits", "h1")?["name"]?.string == "Read before bed")
        // And it's queued with a timestamp the server will accept too.
        let queued = store.pending().changes.first { $0.field == "name" }
        #expect(queued.map { $0.hlc > HLC(ahead, 0, "wrong-date") } == true)
    }
}

@Suite struct Pinning {
    @Test func onlyThePinnedOrConfirmedCertificateIsAccepted() {
        let delegate = PinningDelegate()
        #expect(!delegate.accepts("AA:BB", host: "home"))
        delegate.pinned = "AA:BB"
        #expect(delegate.accepts("AA:BB", host: "home"))
        #expect(!delegate.accepts("CC:DD", host: "home"))
        // A confirmed certificate only counts for the address it was for.
        delegate.trustOnce = (host: "home", fingerprint: "CC:DD")
        #expect(delegate.accepts("CC:DD", host: "home"))
        #expect(!delegate.accepts("CC:DD", host: "elsewhere"))
        #expect(PinningDelegate.fingerprint(of: Data([1, 2, 3])).hasPrefix("03:90:58:C6"))
    }
}

// MARK: - A stand-in server

/// Answers the sync engine's requests in memory, like the real server: one
/// person, field-level changes, a cursor, and its id on every answer.
final class StubServer: @unchecked Sendable {
    let lock = NSLock()
    var id = "home-server"
    var userId = "user-1"
    var cursor = 0
    /// The tag handed out for each point the cursor stopped at. Leave it
    /// empty to act like a server from before history tags.
    var tags: [Int: String] = [:]
    var tagsEnabled = true
    var received: [JSONValue] = []
    var tokensSentTo: [String] = []
    /// Every host the app tried, reachable or not.
    var hostsAsked: [String] = []
    /// Hosts where something else answers: (status, content type, body).
    var impostors: [String: (Int, String, String)] = [:]
    /// Hosts that can't be reached.
    var unreachable: Set<String> = []

    static let shared = StubServer()

    func reset() {
        lock.withLock {
            id = "home-server"; userId = "user-1"; cursor = 0; tags = [:]; tagsEnabled = true
            received = []; tokensSentTo = []; hostsAsked = []; impostors = [:]; unreachable = []
        }
    }

    func answer(_ request: URLRequest, body: Data) -> (Int, [String: String], Data)? {
        lock.withLock {
            let host = request.url?.host() ?? ""
            hostsAsked.append(host)
            if unreachable.contains(host) { return nil }
            if request.value(forHTTPHeaderField: "authorization") != nil { tokensSentTo.append(host) }
            if let (code, type, text) = impostors[host] {
                return (code, ["content-type": type], Data(text.utf8))
            }
            let json: [String: JSONValue]
            switch request.url?.path() ?? "" {
            case "/auth/info":
                json = ["name": "Home", "id": .string(id)]
            case "/auth/login":
                json = [
                    "token": "token-1",
                    "user": ["id": .string(userId), "username": "ryan", "isOwner": true],
                    "server": ["id": .string(id)],
                ]
            case "/sync":
                let request = (try? JSONDecoder().decode([String: JSONValue].self, from: body)) ?? [:]
                let sent = request["changes"]?.array ?? []
                let since = request["since"]?.int ?? 0
                let rewound = tagsEnabled && since > 0
                    && request["sinceTag"]?.string.map { tags[since] != $0 } == true
                received += sent
                cursor += sent.count
                var answer: [String: JSONValue] = ["cursor": .int(cursor), "changes": [], "server": ["id": .string(id)]]
                if tagsEnabled {
                    if tags[cursor] == nil || !sent.isEmpty { tags[cursor] = UUID().uuidString }
                    answer["cursorTag"] = .string(tags[cursor]!)
                    if rewound { answer["rewound"] = true }
                }
                json = answer
            default:
                return (404, ["content-type": "application/json"], Data(#"{"error":"Not found"}"#.utf8))
            }
            return (200, ["content-type": "application/json", "x-openhabits-server": id],
                (try? JSONEncoder().encode(json)) ?? Data())
        }
    }
}

final class StubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        guard let (code, headers, data) = StubServer.shared.answer(request, body: body) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - The sync engine

/// One stand-in server is shared, so these run one at a time.
@Suite(.serialized) @MainActor struct SyncEngineTests {
    let server = StubServer.shared
    let store: LocalStore
    let engine: SyncEngine

    init() throws {
        StubServer.shared.reset()
        store = try LocalStore()
        engine = SyncEngine(store: store, deviceName: "Test", protocolClasses: [StubProtocol.self])
    }

    func signIn() async throws {
        try await engine.signIn(url: "http://home", username: "ryan", password: "pw")
        await engine.syncNow()
    }

    func addHabit(_ name: String) {
        store.write("habits", store.newId(), ["name": .string(name)])
    }

    @Test func editsReachTheServer() async throws {
        try await signIn()
        addHabit("Read")
        await engine.syncNow()
        #expect(engine.status == .idle)
        #expect(store.pendingCount == 0)
        #expect(server.received.contains { $0.object?["value"]?.string == "Read" })
    }

    @Test func aHotelSignInPageDoesntSwallowQueuedChanges() async throws {
        try await signIn()
        server.impostors["home"] = (200, "text/html", "<html>Accept the terms to get online</html>")
        addHabit("Made at the hotel")
        await engine.syncNow()
        #expect(engine.status == .error)
        #expect(store.pendingCount > 0)

        server.impostors = [:]
        await engine.syncNow()
        #expect(store.pendingCount == 0)
        #expect(server.received.contains { $0.object?["value"]?.string == "Made at the hotel" })
    }

    @Test func aNonSyncAnswerKeepsTheQueueEvenWithoutAServerId() async throws {
        try await signIn()
        store.setMeta("serverId", nil)
        server.impostors["home"] = (200, "application/json", #"{"ok":true}"#)
        addHabit("Still queued")
        await engine.syncNow()
        #expect(store.pendingCount > 0)
    }

    @Test func anotherDeviceAtTheHomeAddressGetsNoTokenAndCantSignUsOut() async throws {
        try await signIn()
        store.setMeta("remoteUrl", "https://remote")
        server.impostors["home"] = (401, "application/json", #"{"error":"Please sign in again."}"#)
        server.tokensSentTo = []
        addHabit("At a friend's house")
        await engine.syncNow()
        #expect(engine.status == .idle)
        #expect(!server.tokensSentTo.contains("home"))
        #expect(store.pendingCount == 0)  // went via the remote address
    }

    @Test func somethingElseAtAnAlreadyTrustedRemoteAddressCantSignUsOut() async throws {
        try await signIn()
        store.setMeta("remoteUrl", "https://remote")
        server.unreachable = ["home"]
        await engine.syncNow()  // away from home: the remote address checks out
        #expect(engine.status == .idle)

        // Later something else answers there, without the server's label.
        server.impostors["remote"] = (401, "application/json", #"{"error":"Please sign in again."}"#)
        addHabit("Kept")
        await engine.syncNow()
        #expect(engine.status != .signedOut)
        #expect(store.pendingCount > 0)
    }

    @Test func afterAReinstallSigningInAgainUploadsInsteadOfDeleting() async throws {
        try await signIn()
        addHabit("Only copy is on the phone")
        await engine.syncNow()

        // Wiped and set up again: new server id, new account id, same name.
        server.id = "reinstalled"
        server.userId = "user-2"
        server.cursor = 0
        server.received = []
        await engine.syncNow()
        #expect(engine.status == .error)
        #expect(engine.lastError?.contains("sign in again") == true)

        try await signIn()
        #expect(store.table("habits").values.contains { $0["name"]?.string == "Only copy is on the phone" })
        #expect(server.received.contains { $0.object?["value"]?.string == "Only copy is on the phone" })
    }

    @Test func afterARestoreFromBackupEverythingIsSentAgain() async throws {
        try await signIn()
        addHabit("Before the backup")
        await engine.syncNow()
        addHabit("After the backup")
        await engine.syncNow()

        // Restored: the server's counter goes back, and it lost the edits.
        server.cursor = 1
        server.received = []
        await engine.syncNow()
        #expect(engine.status == .idle)
        let names = server.received.compactMap { $0.object?["value"]?.string }
        #expect(names.contains("Before the backup") && names.contains("After the backup"))
    }

    @Test func aRestoreIsNoticedEvenAfterAnotherDeviceRaisedTheCursorAgain() async throws {
        try await signIn()
        addHabit("Before the backup")
        await engine.syncNow()
        let backupCursor = server.cursor
        addHabit("After the backup")
        await engine.syncNow()
        let lastSeen = server.cursor

        // Restored, and then another device resent everything it had before
        // this one synced, so the counter is already back past this
        // device's cursor. Only the tag shows the history changed.
        server.tags = server.tags.filter { $0.key <= backupCursor }
        server.received = []
        server.cursor = lastSeen + 10
        server.tags[server.cursor] = "after-the-other-device-resent"
        await engine.syncNow()
        #expect(engine.status == .idle)
        let names = server.received.compactMap { $0.object?["value"]?.string }
        #expect(names.contains("Before the backup") && names.contains("After the backup"))
    }

    @Test func anOlderServerWithoutTagsStillSyncs() async throws {
        server.tagsEnabled = false
        try await signIn()
        addHabit("No tags here")
        await engine.syncNow()
        #expect(engine.status == .idle)
        #expect(store.meta("cursorTag") == nil)
        server.received = []
        await engine.syncNow()
        #expect(engine.status == .idle)
        #expect(server.received.isEmpty)  // nothing resent without a reason
    }

    @Test func aPairingCodeForAnotherServerSaysWhatSwitchingCosts() async throws {
        #expect(engine.replacementWarning(for: "http://home") == nil)  // not signed in yet
        try await signIn()
        #expect(engine.replacementWarning(for: "http://home") == nil)  // same server
        server.unreachable = ["home"]
        addHabit("Not sent yet")
        let warning = engine.replacementWarning(for: "https://elsewhere.example")
        #expect(warning?.contains("http://home") == true)
        #expect(warning?.contains("as ryan") == true)
        #expect(warning?.contains("1 change that hasn't been sent yet") == true)
    }

    @Test func anApprovalIsForgottenWhenSignInFails() async throws {
        engine.trustCertificate("CC:DD", for: "http://home")
        server.impostors["home"] = (400, "application/json", #"{"error":"That code doesn't work."}"#)
        await #expect(throws: (any Error).self) { try await engine.redeem(url: "http://home", code: "X") }
        #expect(engine.pinning.trustOnce == nil)
        #expect(store.meta("fingerprint") == nil)
    }

    @Test func aReinstallAtANewAddressKeepsAndUploadsTheHabits() async throws {
        try await signIn()
        addHabit("Only copy is on the phone")
        await engine.syncNow()
        server.id = "new-box"
        server.userId = "user-2"
        server.cursor = 0
        server.received = []
        try await engine.signIn(url: "http://new-box", username: "ryan", password: "pw")
        await engine.syncNow()
        #expect(store.table("habits").values.contains { $0["name"]?.string == "Only copy is on the phone" })
        #expect(server.received.contains { $0.object?["value"]?.string == "Only copy is on the phone" })
    }

    @Test func signingInDoesntFallBackToThePreviousServersDirectory() async throws {
        try await signIn()
        store.setMeta("directoryLookup", "https://directory.example/v1/servers/old")
        store.setMeta("directoryKey", "x")
        server.unreachable = ["new-box"]
        server.hostsAsked = []
        await #expect(throws: (any Error).self) {
            try await engine.signIn(url: "http://new-box", username: "ryan", password: "pw")
        }
        #expect(!server.hostsAsked.contains("directory.example"))
        #expect(engine.serverUrl == "http://home")
    }

    @Test func signingInToAnotherServerForgetsTheOldCertificate() async throws {
        store.setMeta("serverUrl", "https://old")
        store.setMeta("fingerprint", "AA:BB")
        engine.pinning.pinned = "AA:BB"
        try await signIn()
        #expect(engine.pinning.pinned == nil)
    }
}
