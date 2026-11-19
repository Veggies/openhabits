# Working on OpenHabits

Everything for building, testing and understanding the code. For setting up a server, see [SERVER.md](SERVER.md).

## Building the apps

### iPhone, iPad and Mac

The Apple app is native SwiftUI, in `apps/apple`. The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). It needs Xcode 26 or newer and runs on iOS 26 and macOS 26 or newer.

```sh
cd apps/apple
xcodegen                         # makes OpenHabits.xcodeproj
open OpenHabits.xcodeproj        # then run the OpenHabits scheme
```

In debug builds, launching with `-sampleData YES` starts from a fresh, separate set of sample habits (your own data is left alone), and `-startTab progress` opens on a tab.

### Windows and Linux

The Flutter app is in `apps/client`, with Flutter pinned by [FVM](https://fvm.app) (`.fvmrc`). Each build has to be made on its own operating system.

```sh
cd apps/client
fvm flutter run -d windows       # or: linux
fvm flutter build windows        # release builds: windows, linux
```

The first launch walks through connecting to your server and building a first habit.

## How sync works

Every edit is a field-level `Change` (table, row, field, value, timestamp). The
timestamp is a hybrid logical clock, so edits are ordered correctly even when
device clocks disagree. Devices keep a full local SQLite copy and work offline;
edits are queued and sent to `POST /sync`, which returns everything newer than
the device's cursor in the same round trip.

Each answer also carries a `cursorTag`, a random tag for that point in the
server's history, and devices send it back as `sinceTag`. If the server was
restored from a backup taken after a device last synced, it doesn't have that
tag and answers `"rewound": true`, so the device sends everything again. This
still works when other devices have already counted the cursor back up past the
device's own. Devices also treat a cursor lower than their own as a restore,
which covers servers from before tags.

Conflicts resolve per field with last-write-wins (`packages/core/lib/src/merge.dart`):
renaming a habit on one device while changing its color on another keeps both
edits. Deleting sets a `_deleted` field, so deleting and restoring sync like any
other edit.

## Layout

```
fixtures       Shared test data every implementation is checked against
packages/core   Shared by client and server: sync clock, merge rule, models,
                habit logic
apps/server     Server (Dart, SQLite): setup page, accounts, sync, remote
                access
apps/apple      iPhone, iPad and Mac app (SwiftUI); HabitsCore is the Swift
                version of packages/core and the client's sync
apps/client     Flutter app (Windows, Linux)
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


Shared test data lives in [`fixtures/`](../fixtures/README.md).
