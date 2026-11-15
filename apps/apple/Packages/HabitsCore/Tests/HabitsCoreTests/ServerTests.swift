import Foundation
import Testing

@testable import HabitsCore

/// Syncs with a real server. Runs only when HABITS_TEST_SERVER is set, e.g.
///
///     PORT=18080 DB_PATH=/tmp/test.sqlite OWNER_USERNAME=tester \
///       OWNER_PASSWORD=testpass123 dart run bin/server.dart
///     HABITS_TEST_SERVER=http://localhost:18080 swift test
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HABITS_TEST_SERVER"] != nil))
struct WithAServer {
    let url = ProcessInfo.processInfo.environment["HABITS_TEST_SERVER"] ?? ""
    let username = ProcessInfo.processInfo.environment["HABITS_TEST_USER"] ?? "tester"
    let password = ProcessInfo.processInfo.environment["HABITS_TEST_PASSWORD"] ?? "testpass123"

    func device(_ name: String) throws -> (Repo, SyncEngine) {
        let store = try LocalStore()
        return (Repo(store: store), SyncEngine(store: store, deviceName: name))
    }

    @Test func twoDevicesStayInStep() async throws {
        let (phoneRepo, phone) = try device("Test iPhone")
        let info = try await phone.serverInfo(url)
        #expect(!info.name.isEmpty)
        let account = try await phone.signIn(url: info.url, username: username, password: password)
        #expect(account.username == username)

        let name = "Swift test \(UUID().uuidString.prefix(6))"
        let id = phoneRepo.createHabit(["name": .string(name), "weekdays": [1, 3, 5], "duration": 20])
        phoneRepo.setDone(id, phoneRepo.today, true)
        await phone.syncNow()
        #expect(phone.status == .idle, "\(phone.lastError ?? "")")
        #expect(phone.store.pendingCount == 0)

        // A second device signed in with a pairing code from the first.
        let (code, pairing) = try await phone.pairingCode()
        #expect(!code.isEmpty)
        let (macRepo, mac) = try device("Test Mac")
        try await mac.redeem(url: pairing.server, code: code)
        await mac.syncNow()
        let synced = try #require(macRepo.habit(id))
        #expect(synced.name == name)
        #expect(synced.weekdays == [1, 3, 5])
        #expect(synced.duration == 20)
        #expect(macRepo.isDone(id, macRepo.today))

        // Both edit the same field: the later edit wins everywhere.
        macRepo.updateHabit(id, ["name": "From the Mac"])
        try await Task.sleep(for: .milliseconds(5))
        phoneRepo.updateHabit(id, ["name": "From the phone"])
        await mac.syncNow()
        await phone.syncNow()
        await mac.syncNow()
        #expect(macRepo.habit(id)?.name == "From the phone")
        #expect(phoneRepo.habit(id)?.name == "From the phone")

        // The calendar link works.
        let link = try await phone.calendarLink()
        #expect(link.url.contains("/calendar/"))

        phoneRepo.deleteHabit(id)
        await phone.syncNow()
        await mac.syncNow()
        #expect(macRepo.habit(id)?.deleted == true)
        await phone.signOut()
        await mac.signOut()
    }

    @Test func wrongPasswordExplainsItself() async throws {
        let (_, engine) = try device("Test")
        await #expect(throws: SyncError.self) {
            try await engine.signIn(url: url, username: username, password: "nope-nope")
        }
        #expect(!engine.isConfigured)
    }
}
