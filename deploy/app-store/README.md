# App Store listing

Everything to paste into App Store Connect for OpenHabits (iPhone, iPad and Mac). The screenshots are in `screenshots/`, already at the sizes Apple asks for. They show sample habits, not anyone's real data.

The app icon doesn't need uploading. App Store Connect takes it from the build.

## App information (shared by iOS and macOS)

| Field | Value |
|---|---|
| Name (30 max) | `OpenHabits` |
| Subtitle (30 max) | `Small steps, lasting habits` |
| Primary category | Health & Fitness |
| Secondary category | Productivity |
| Content rights | Doesn't contain, show or access third-party content |
| Age rating | Answer "None" / "No" to everything, which gives 4+ |
| Price | Free |
| Privacy policy URL | `https://github.com/Veggies/openhabits/blob/main/PRIVACY.md` |
| Support URL | `https://github.com/Veggies/openhabits/issues` |
| Marketing URL (optional) | `https://github.com/Veggies/openhabits` |
| Copyright | `2026 Ryan Ruddock` |

Keep "Atomic Habits" out of the name, subtitle and keywords. It's the title of James Clear's book (and a trademark), and Apple rejects other people's trademarks in those fields. A factual mention in the description is fine; the last line of the description says the app isn't affiliated with him, so it can't read as an endorsement.

## App Privacy

Choose **"No, we do not collect data from this app."** That gives the "Data Not Collected" label. Everything stays on the device and on the person's own server, which the developer can't access. See `PRIVACY.md`.

## Version page (paste into both the iOS and macOS versions)

**Promotional text** (170 max, can be changed any time without a new build):

```
Build habits that stick, one small step at a time. Private by design: your habits live on your device and, if you like, on a server you run yourself.
```

**Keywords** (100 max, commas, no spaces):

```
habit tracker,routine,streak,goals,daily,self-hosted,private,focus timer,pomodoro,reminders,review
```

**Description** (4000 max):

```
OpenHabits helps you build good habits and break bad ones, one small step at a time. It's built around the ideas in James Clear's book Atomic Habits, and your data stays yours.

CHECK IN EACH DAY
Tick off what you did with one tap. For habits you're breaking, mark the days you stayed clear.

START SMALL, THEN GROW
Begin with a version so small you can't say no, like reading one page. Every couple of weeks the app asks whether it still feels right, and you can make it a little bigger when you're ready.

NEVER MISS TWICE
Missing one day doesn't break your streak. The app reminds you to get back on track before you miss a second.

SEE HOW IT'S GOING
A square for every week shows how each habit is going, with a short, plain summary next to it.

LOOK BACK EACH WEEK
A short weekly review asks what went well and what you'd change. A scorecard helps you notice the habits you already have.

A PLAN FOR EVERY HABIT
For each habit, decide who you want to become, and use the four laws: make it obvious, attractive, easy and satisfying.

FOCUS TIMER AND REMINDERS
A focus timer with breaks, a reminder at each habit's time, and your habits in your calendar app.

YOUR DATA, YOUR SERVER
OpenHabits works fully on its own, with no account. If you'd like your iPhone, iPad and Mac to stay in sync, connect them to your own OpenHabits server, for example on a home NAS. Each person in your household gets a private account, and it works away from home too. The server is free and open source.

No ads, no tracking, no subscription.

OpenHabits is an independent app. It isn't affiliated with or endorsed by James Clear.
```

**What's New** (first version):

```
The first release of OpenHabits.
```

## App Review information

- **Sign-in required:** No. The app works fully without an account or server.
- **Notes for the reviewer:**

```
OpenHabits works fully on the device without an account. On first launch, choose "Skip, and use it on this device only".

Syncing between devices is optional. It needs a server that the user hosts themselves (free and open source: https://github.com/Veggies/openhabits). No developer-run account or service is needed to use the app.
```

## Screenshots

| Upload to | Folder | Size |
|---|---|---|
| iPhone 6.9" display | `screenshots/iphone-6.9` | 1320 × 2868 |
| iPhone 6.1" / 6.3" display | `screenshots/iphone-6.3` | 1206 × 2622 |
| iPad 12.9" / 13" display | `screenshots/ipad-13` | 2064 × 2752 |
| Mac | `screenshots/mac` | 1440 × 900 |

Upload them in the numbered order. The first two or three are what people see in search results. App Store Connect asks for whichever iPhone size it currently needs; both are here. The Mac ones are 1440 × 900 because the Mac they were taken on has a standard (non-Retina) display, so that's their sharpest size.

## Header and search results artwork

| Upload to | File | Size |
|---|---|---|
| Header | `artwork/header-3840x1646.png` | 3840 × 1646 |
| Search results | `artwork/search-3840x2560.png` | 3840 × 2560 |

Both use the icon, the name and tagline, and the iPad and iPhone screens. The important parts sit in the middle, in case the edges are cropped on smaller screens.

To retake them after the app changes, build the Debug app and launch it with `-sampleData YES` plus `-openScreen checkIn|editorPlan` or `-startTab progress|reflect|focus`. See `docs/DEVELOPMENT.md`.
