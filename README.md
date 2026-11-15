# Tasks

A self-hostable habit tracker. Build habits or break them, start small and grow them over time, see how each week went, and use a focus timer to help. The Atomic Habits method is built in, and it's optional. Your data lives on your own server. One Flutter codebase builds for iOS, Android, macOS, Windows and Linux, and a small Dart server keeps your devices in sync.

## Set up the server

**TrueNAS:** until Tasks is in the catalog, go to *Apps → Discover Apps → ⋮ →
Install via YAML* and paste [`deploy/truenas/tasks.yaml`](deploy/truenas/tasks.yaml)
(set the dataset path first).
**Anywhere else with Docker:** `docker compose up -d`.

Then open `http://<your-server>:8080` in a browser. The setup page asks you to
create your account, and afterwards is where the owner manages the server.

**Remote access.** On the setup page, click *Enable remote access*. The server
asks your router to open a port (UPnP), checks it can be reached, and secures
the connection with its own certificate, which devices learn to trust when
they're signed in. Nothing extra is installed on phones or computers.

- If your router doesn't respond, the page explains how to forward the port by hand.
- If your internet provider shares one address between customers (CGNAT),
  nothing outside can connect in directly. The page says so and walks you
  through a free relay with Tailscale Funnel, installed on the server only.
- Already have a domain or reverse proxy? Enter it as a custom public address.

**Signing in.** Each person has their own account and private data; the owner
adds people on the setup page. A new device signs in with the server address
and a password, or by scanning the QR code from *Add a device* (on the setup
page or in the app's Settings), which also teaches it the remote address.
Single sign-on with Google or another OpenID Connect provider is optional and
needs a public address with a real domain.

## Run the app

### iPhone, iPad and Mac

The Apple app is native SwiftUI, in `apps/apple`. The Xcode project is
generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). It needs Xcode 26 or newer and runs on iOS 26 and
macOS 26 or newer.

```sh
cd apps/apple
xcodegen                         # makes OpenHabits.xcodeproj
open OpenHabits.xcodeproj        # then run the OpenHabits scheme
```

In debug builds, launching with `-sampleData YES` fills an empty app with
sample habits, and `-startTab progress` opens on a tab.

### Android, Windows and Linux

Flutter is pinned with [FVM](https://fvm.app) (`.fvmrc`).

```sh
cd apps/client
fvm flutter run -d macos        # or: ios, android, windows, linux
fvm flutter build macos         # release builds: ios, apk, windows, linux
```

Windows and Linux builds must be made on those operating systems. The first
launch walks through connecting to your server and, optionally, setting up
habits with the Atomic Habits framework.

## Features

### Habits

- **Build or break.** Check a habit off when you've done it. For a habit you're breaking, checking it off means you stayed clear that day.
- **Progress.** One row per habit and one square per week, with the number of days you did it. Each habit also gets a plain summary of the last four weeks: going strong, getting there, or struggling.
- **A time and a length.** Any habit can have a time of day and say how long it takes.

### The Atomic Habits method (optional)

Turn it on in the setup wizard or Settings, and habits gain:

- who you want to become ("I am a reader"), with each check-in counted as a vote for it
- the four laws: when and where, "After I…", pairing it with something you enjoy, and a reward right after; turned around for habits you're breaking, with an optional habit contract
- start small and grow it: begin with a tiny version, and every two weeks the app checks in. If it's sticking, it asks whether it's starting to feel too easy; if you've been missing it a lot, it offers to make it smaller
- streaks that forgive a single missed day, with a nudge to not miss two in a row
- a habits scorecard and a weekly review

### Focus

A focus timer with a break in between. A session can be linked to one of your habits.

## How sync works

Every edit is a field-level `Change` (table, row, field, value, timestamp). The
timestamp is a hybrid logical clock, so edits are ordered correctly even when
device clocks disagree. Devices keep a full local SQLite copy and work offline;
edits are queued and sent to `POST /sync`, which returns everything newer than
the device's cursor in the same round trip.

Conflicts resolve per field with last-write-wins (`packages/core/lib/src/merge.dart`):
renaming a habit on one device while changing its color on another keeps both
edits. Deleting sets a `_deleted` field, so deleting and restoring sync like any
other edit.

## Layout

```
packages/core   Shared by client and server: sync clock, merge rule, models,
                habit logic
apps/server     Server (Dart, SQLite): setup page, accounts, sync, remote
                access
apps/apple      iPhone, iPad and Mac app (SwiftUI); HabitsCore is the Swift
                version of packages/core and the client's sync
apps/client     Flutter app (Android, Windows, Linux)
deploy/truenas  TrueNAS app config and catalog plan
```

## Tests

```sh
(cd packages/core && fvm dart test)
(cd apps/server && fvm dart test)
(cd apps/client && fvm flutter test)
(cd apps/apple/Packages/HabitsCore && swift test)
```

The Swift tests can also sync with a real server: start one with
`PORT=18080 DB_PATH=/tmp/test.sqlite OWNER_USERNAME=tester OWNER_PASSWORD=testpass123 fvm dart run bin/server.dart`
in `apps/server`, then run `HABITS_TEST_SERVER=http://localhost:18080 swift test`.
