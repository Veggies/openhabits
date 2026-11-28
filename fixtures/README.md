# Shared test data

Every implementation reads these files in its tests, so the server, the
directory, the Flutter app and the Apple app are all held to the same
answers. If one of them changes how it works, its tests fail here first.

| File | What it holds | Read by |
|---|---|---|
| `hlc.json` | Clock ordering (including ties broken by device), `send`, `receive` (including a device whose date is far ahead) and the merge rule. Timestamps are in the packed text form the server stores. | `packages/core/test/hlc_test.dart` (the server and Flutter app use core), `HabitsCoreTests/SyncEngineTests.swift` |
| `days_off.json` | Streaks, "never miss twice" and completion when a habit has days off (the `off` field on a day's check-in). | `packages/core/test/habit_test.dart`, `HabitsCoreTests/CoreTests.swift` |
| `rewards.json` | Reading rewards and their prices, and the tomatoes left to spend today. | `packages/core/test/habit_test.dart`, `HabitsCoreTests/CoreTests.swift` |
| `tasks.json` | Reading tasks, and where each one goes: its place in the Tasks list, how its due date reads and its box in the matrix. | `packages/core/test/habit_test.dart`, `HabitsCoreTests/CoreTests.swift` |
| `directory_record.json` | One address update signed by the server's real signing code, with a test-only key. | `apps/server/test/directory_test.dart`, `services/directory/test/directory.test.js`, `apps/client/test/trust_test.dart`, `HabitsCoreTests/SyncEngineTests.swift` |

## Changing them

- **hlc.json** is written by hand. Add a case when you find behaviour worth
  pinning down, and work out the expected answer from the rules in
  `packages/core/lib/src/hlc.dart`. Every implementation must pass it.
- **days_off.json**, **rewards.json** and **tasks.json** are written by hand, like `hlc.json`. Work out each
  expected number from the rules in `packages/core/lib/src/models.dart`.
- **directory_record.json** is made by the server:
  `cd apps/server && fvm dart run tool/make_directory_record.dart`. Its key
  is only for tests.

After changing any of them, run all four suites: `fvm dart test` in
`packages/core` and `apps/server`, `fvm flutter test` in `apps/client`,
`swift test` in `apps/apple/Packages/HabitsCore`, and `npm test` in
`services/directory`.
