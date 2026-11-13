# Tasks

A self-hostable task manager in the spirit of TickTick: lists, tasks with subtasks and tags, natural-language quick add, repeating tasks, a calendar (day/week/month/year) with your external calendars overlaid, habit tracking with optional Atomic Habits coaching, and a Pomodoro focus timer. One Flutter codebase builds for iOS, Android, macOS, Windows and Linux; a small Dart server syncs your devices.

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

**External calendars.** Add Google (secret iCal link), iCloud (app-specific
password) or any CalDAV/`.ics` calendar on the setup page. They refresh every
15 minutes and show read-only in the app's Calendar.

## Run the app

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

### Quick add

| You type | You get |
|---|---|
| `tomorrow`, `fri`, `next week`, `in 3 days`, `nov 20`, `11/20` | Due date |
| `5pm`, `at 9:30am`, `17:00`, `noon` | Due time |
| `every day`, `weekly`, `every 2 weeks`, `every mon wed fri`, `every weekday` | Repeat |
| `!high` `!med` `!low` (or `!3` `!2` `!1`) | Priority |
| `#tag` | Tag |
| `^List` | List (created if missing) |

### Habits and Atomic Habits

Habits can be built (check in when done) or broken (log slips; tracks days
clean). The Atomic Habits framework is optional. Turn it on in the setup
wizard or Settings, and habits gain:

- an identity ("I am a reader"), with each check-in counted as a vote for it
- the four laws: when and where, habit stacking ("After I…"), temptation bundling, a two-minute version and a reward; inverted for habits you're breaking, with an optional habit contract
- "never miss twice" streaks that survive a single miss, with a nudge the day after
- a habits scorecard and a weekly review

## How sync works

Every edit is a field-level `Change` (table, row, field, value, timestamp). The
timestamp is a hybrid logical clock, so edits are ordered correctly even when
device clocks disagree. Devices keep a full local SQLite copy and work offline;
edits are queued and sent to `POST /sync`, which returns everything newer than
the device's cursor in the same round trip.

Conflicts resolve per field with last-write-wins (`packages/core/lib/src/merge.dart`):
renaming a task on one device while completing it on another keeps both edits.
Deleting sets a `_deleted` field, so Trash and Restore sync like any edit.

## Layout

```
packages/core   Shared by client and server: sync clock, merge rule, models,
                repeat rules, habit logic, quick-add parser
apps/server     Server (Dart, SQLite): setup page, accounts, sync, remote
                access, calendar import
apps/client     Flutter app
deploy/truenas  TrueNAS app config and catalog plan
```

## Tests

```sh
(cd packages/core && fvm dart test)
(cd apps/server && fvm dart test)
(cd apps/client && fvm flutter test)
```
