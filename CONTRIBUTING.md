# Contributing to OpenHabits

Thanks for wanting to help! Bug reports, ideas, fixes and new features are all welcome.

## Before you start

- **Found a bug?** [Open an issue](https://github.com/Veggies/openhabits/issues/new/choose) with the bug form. Say which device and version you're on, and what you expected to happen.
- **Want to add or change something bigger?** Open an issue first and describe it, so we can agree on the approach before you spend time on it. Small fixes (typos, obvious bugs) can go straight to a pull request.
- **Found a security problem?** Please don't open a public issue. See [SECURITY.md](SECURITY.md).

## How the project fits together

| Folder | What it is |
|---|---|
| `apps/apple` | The iPhone, iPad and Mac app (SwiftUI). `Packages/HabitsCore` is the shared logic and sync. |
| `apps/client` | The Windows and Linux app (Flutter). |
| `apps/server` | The sync server (Dart, runs in Docker). |
| `packages/core` | Shared Dart logic used by the Flutter app and the server. |
| `services/directory` | The small directory service that helps apps find a server when its address changes. |
| `fixtures` | Shared test data that every part checks itself against. |

[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) explains how to build and run each part, and how sync works.

## A few ground rules

- **Keep the two apps in step.** A new feature usually goes into the Apple app first, then the same thing into the Flutter app, so both look and behave alike. If you can only do one, say so in your pull request and someone can help with the other.
- **Sync must stay compatible.** If you add something that syncs, both apps need to read it, and older apps must not break when they see it (they ignore fields they don't know). If you change a format the apps and server share, update the matching file in `fixtures/` so every part is tested against it.
- **Write the app's words plainly.** Text in the app should read like a person talking: full, friendly sentences, no jargon.
- **Keep changes focused.** One pull request per fix or feature makes it much easier to review.

## Making a change

1. Fork the repository and create a branch from `main`, e.g. `fix-reminder-time`.
2. Make your change, with tests where it makes sense.
3. Run the tests for the parts you touched:

   | Part | Command |
   |---|---|
   | Apple core | `cd apps/apple/Packages/HabitsCore && swift test` |
   | Flutter app | `cd apps/client && fvm flutter analyze && fvm flutter test` |
   | Server and core | `fvm dart test` in `apps/server` and in `packages/core` |
   | Directory | `cd services/directory && npm test` |

4. Open a pull request against `main` and fill in the template. Screenshots help a lot for anything you can see.

The same tests run automatically on your pull request. A maintainer reviews every pull request before it's merged. If changes are needed, just push more commits to the same branch.

## Licence

The apps and shared code are MIT-licensed, and the server is AGPL-3.0-or-later (see [LICENSE](LICENSE) and [apps/server/LICENSE](apps/server/LICENSE)). By contributing, you agree that your contribution is licensed the same way as the part of the project it's in.
