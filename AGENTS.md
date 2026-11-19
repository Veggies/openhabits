# AGENTS.md

Guidance for coding agents (Claude Code, Codex, Cursor and others) working on OpenHabits. People are welcome to read it too. `CLAUDE.md` only points here, so every agent follows the same rules.

OpenHabits is a self-hosted habit tracker built around the ideas in *Atomic Habits*. There's a SwiftUI app for iPhone, iPad and Mac, a Flutter app for Windows and Linux, and a Dart sync server that runs in Docker. Read [CONTRIBUTING.md](CONTRIBUTING.md) for the folder layout and the full contribution rules, and [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for building, testing and how sync works.

## Rules

1. **A person is accountable.** Whoever runs an agent answers for every line it writes, and for everything it posts on issues and pull requests.
2. **Swift leads, Flutter follows.** Build a feature in the Apple app (`apps/apple`) first, then the same thing in the Flutter app (`apps/client`), so both look and behave alike. If you only do one, say which one still needs it.
3. **Sync must stay compatible.** Anything that syncs is read by both apps and the server. Older apps ignore fields they don't know, so add fields rather than change or remove them. If a shared format changes, update the matching file in `fixtures/`.
4. **Write the app's words like a person talking.** Use full, friendly sentences in plain words: "You missed this last time, so try not to miss it two days in a row," not "Missed last time. Never miss twice." Explain the book's terms ("habit stacking", "never miss twice") in everyday words. Write from the reader's side ("you'll get a quick check-in"), not "the app does…", and never use "we": the server is self-hosted, so nobody is on the other end.
5. **The Atomic Habits features are always on.** Identity, plans, starting small, never missing twice, the scorecard and the weekly review are the core of the app. Don't add a switch to turn them off. Plan fields can stay optional to fill in.
6. **Nothing extra to install on devices.** People install the server once, then sign in from each app, like Plex. Don't propose anything that needs extra software on each device, such as a VPN client. Server-side solutions are fine.
7. **Verify, don't guess.** Open a definition before you use it, and confirm a bug's cause in the code before fixing it.
8. **Keep fixes narrow and tested.** One issue, one pull request. Add a test that fails without the fix. A version bump is its own pull request.
9. **Report only what ran.** Say which tests you ran and what you checked by hand. If you couldn't build or run something, say so.
10. **Follow the pull request template in full.** Link the issue (`Fixes #12`). Add before-and-after screenshots for anything visible: you can't drag images in, so write `![Before](./before.png)` in the description file and pass each image with `--attach ./before.png` to `gh pr create` or `gh pr edit` (GitHub CLI 2.99 or later). Never commit screenshots to the repository or to a branch. Say how AI was used. Right after opening it, comment `@coderabbitai review` on it to start the automatic code review, then answer or fix what it finds.
11. **Keep secrets and personal details out** of the code, logs, commits and pull requests.
12. **Finish the job.** After opening a pull request, wait for its checks. If one fails, read why and fix it, then check again. The pull request isn't done until every check passes.

## Building and testing

| Part | Commands |
|---|---|
| Apple app | `cd apps/apple && xcodegen`, then build the `OpenHabits` scheme. The Xcode project isn't checked in. Run `xcodegen` again after adding Swift files. |
| Apple core | `cd apps/apple/Packages/HabitsCore && swift test` |
| Flutter app | `cd apps/client && fvm flutter analyze && fvm flutter test` |
| Server and core | `fvm dart test` in `apps/server` and in `packages/core` |
| Directory service | `cd services/directory && npm test` |
| Everything syncing together | `tool/cross_app_check.sh` (needs Docker) |

Run `fvm dart format .` in every Dart folder you change; CI fails on unformatted code.

Debug builds of the Apple app are a separate app, "OpenHabits Dev", with their own bundle ID and data, so testing never touches someone's real habits. Launch them with `-sampleData YES` to start from a fresh set of sample habits.
