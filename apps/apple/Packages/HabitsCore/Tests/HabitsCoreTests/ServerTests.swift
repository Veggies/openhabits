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

/// One half of the Apple ↔ Android check in `tool/cross_app_check.sh`: the
/// Swift core writes a habit, the Flutter core edits it, the Swift core reads
/// the edit back. Runs only when the script sets HABITS_CROSS_STEP.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HABITS_CROSS_STEP"] != nil))
struct CrossApp {
    let env = ProcessInfo.processInfo.environment
    var url: String { env["HABITS_TEST_SERVER"] ?? "" }
    var name: String { env["HABITS_CROSS_NAME"] ?? "" }

    func signedIn() async throws -> (Repo, SyncEngine) {
        let store = try LocalStore()
        let (repo, engine) = (Repo(store: store), SyncEngine(store: store, deviceName: "Cross-app iPhone"))
        _ = try await engine.signIn(url: url, username: env["HABITS_TEST_USER"] ?? "tester",
                                    password: env["HABITS_TEST_PASSWORD"] ?? "testpass123")
        await engine.syncNow()
        #expect(engine.status == .idle, "\(engine.lastError ?? "")")
        return (repo, engine)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HABITS_CROSS_STEP"] == "write"))
    func appleWrites() async throws {
        let (repo, engine) = try await signedIn()
        let id = repo.createHabit(["name": .string(name), "weekdays": [2, 4], "duration": 15])
        repo.setDone(id, repo.today, true)
        await engine.syncNow()
        #expect(engine.store.pendingCount == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HABITS_CROSS_STEP"] == "read"))
    func appleReadsAndroidsEdit() async throws {
        let (repo, engine) = try await signedIn()
        let habit = try #require(repo.habits.first { $0.name == "\(name) (from Android)" },
                                 "The edit made by the Flutter app didn't reach the Apple app")
        #expect(habit.weekdays == [2, 4])
        #expect(habit.duration == 25)
        #expect(!repo.isDone(habit.id, repo.today), "Android unticked today")
        repo.deleteHabit(habit.id)
        await engine.syncNow()
        await engine.signOut()
    }
}

/// The directory fallback against a real server, a real router and the real
/// directory code (run by tool/directory_check.sh). The device learns the
/// server's addresses, then every address it knows stops working, as when
/// the home's internet address changes while it's away. It must find the
/// server again through the directory.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HABITS_DIRECTORY_TEST"] != nil))
@MainActor
struct DirectoryFallback {
    let env = ProcessInfo.processInfo.environment
    var url: String { env["HABITS_TEST_SERVER"] ?? "" }

    @Test func findsTheServerAfterItsAddressChanges() async throws {
        let store = try LocalStore()
        let repo = Repo(store: store)
        let first = SyncEngine(store: store, deviceName: "Directory test")
        _ = try await first.signIn(url: url, username: env["HABITS_TEST_USER"] ?? "tester",
            password: env["HABITS_TEST_PASSWORD"] ?? "testpass123")
        await first.syncNow()
        let realRemote = try #require(first.remoteUrl, "Remote access should be on")
        #expect(store.meta("directoryLookup") != nil)

        // Everything this device knows is now wrong (192.0.2.x never answers).
        store.setMeta("serverUrl", "http://192.0.2.1:9")
        store.setMeta("remoteUrl", "https://192.0.2.1:9")
        let away = SyncEngine(store: store, deviceName: "Directory test")
        let name = "Directory test \(UUID().uuidString.prefix(6))"
        let id = repo.createHabit(["name": .string(name)])
        await away.syncNow()
        #expect(away.status == .idle, "\(away.lastError ?? "")")
        #expect(store.pendingCount == 0)
        #expect(away.remoteUrl == realRemote)

        repo.deleteHabit(id)
        await away.syncNow()
    }
}
