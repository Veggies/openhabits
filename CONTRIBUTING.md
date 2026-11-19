# Contributing to OpenHabits

Thanks for wanting to help! Bug reports, ideas, fixes and new features are all welcome.

Everyone taking part is expected to follow the [code of conduct](CODE_OF_CONDUCT.md).

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

   For the Dart parts, also run `fvm dart format .` in each folder you changed. The checks fail on code that isn't formatted.

4. Open a pull request against `main` and fill in the template.

## What happens on your pull request

- **The tests run automatically** for every part you changed, plus a formatting check and a check that the server's Docker image still builds. They all have to pass before the pull request can be merged. If one fails, open it from the pull request's *Checks* tab to see why.
- **Anything you can see needs a screenshot.** If you change an app screen, the server's setup page or an icon, add a screenshot or short video to the description, ideally before and after. If nothing visible changed, tick the box that says so. A check enforces this, and it runs again when you edit the description. There are two ways to add them:
  - **Drag and drop.** While you write the description on GitHub, drag your images or video into the Screenshots section, or paste them in. GitHub uploads them and adds the links for you. This works for everyone.
  - **With the GitHub CLI.** If you can push to this repository, you can do it from the terminal instead. In your description file, write a normal image link to each file, like `![Before](./before.png)`, then add `--attach ./before.png` for each one to `gh pr create` or `gh pr edit`. GitHub uploads them and swaps in the links. You'll need GitHub CLI 2.99 or later.

  Either way, please don't commit screenshots to the repository or to a branch. They'd stay in its history for good, and everyone who clones it would download them.
- **Link the issue it's for.** Put a line like `Fixes #12` in the description. Small changes that don't need an issue, like a typo or a version bump, can tick "No issue needed" instead. A check enforces this too.
- **Changed code but no tests?** You'll see a reminder. Bug fixes and new behaviour should come with a test that would have caught the problem, so it can't quietly come back.
- **CodeRabbit reviews every pull request.** It's an automatic code review, free for open-source projects. To start it, comment `@coderabbitai review` on your pull request (anyone can). Its comments are suggestions: reply if you disagree, and fix what's right.
- **A maintainer reviews every pull request** before it's merged. If changes are needed, just push more commits to the same branch.

## Licence

The apps and shared code are MIT-licensed, and the server is AGPL-3.0-or-later (see [LICENSE](LICENSE) and [apps/server/LICENSE](apps/server/LICENSE)). By contributing, you agree that your contribution is licensed the same way as the part of the project it's in.
