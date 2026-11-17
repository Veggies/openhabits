import HabitsCore
import SwiftUI

extension Color {
    /// A colour stored as 0xAARRGGBB, as the habits table does.
    init(argb: Int) {
        self.init(
            .sRGB,
            red: Double((argb >> 16) & 0xFF) / 255,
            green: Double((argb >> 8) & 0xFF) / 255,
            blue: Double(argb & 0xFF) / 255,
            opacity: Double((argb >> 24) & 0xFF) / 255)
    }
}

/// Accent colours to choose from. Apple's system colours, which adjust
/// for light and dark mode. "System" follows the device.
let accentChoices: [(name: String, label: String, color: Color)] = [
    ("system", "System", .accentColor),
    ("blue", "Blue", .blue), ("purple", "Purple", .purple), ("pink", "Pink", .pink),
    ("red", "Red", .red), ("orange", "Orange", .orange), ("yellow", "Yellow", .yellow),
    ("green", "Green", .green), ("mint", "Mint", .mint), ("teal", "Teal", .teal),
    ("indigo", "Indigo", .indigo), ("graphite", "Graphite", .gray),
]

/// Colours offered for habits: Apple's system palette.
let habitColors: [Int] = [
    0xFF00_7AFF, 0xFF58_56D6, 0xFFAF_52DE, 0xFFFF_2D55, 0xFFFF_3B30, 0xFFFF_9500,
    0xFFFF_CC00, 0xFF34_C759, 0xFF00_C7BE, 0xFF30_B0C7, 0xFF32_ADE6, 0xFFA2_845E,
]

/// Icons for habits, keyed by the name stored on the habit (shared with the
/// Android app), as SF Symbols.
let habitSymbols: [(key: String, symbol: String)] = [
    ("check", "checkmark.circle"), ("book", "book"), ("run", "figure.run"),
    ("walk", "figure.walk"), ("bike", "bicycle"), ("gym", "dumbbell"),
    ("yoga", "figure.mind.and.body"), ("water", "drop"), ("sleep", "bed.double"),
    ("sun", "sun.max"), ("food", "fork.knife"), ("fruit", "leaf"), ("pill", "pills"),
    ("tooth", "mouth"), ("journal", "note.text"), ("write", "pencil"),
    ("study", "graduationcap"), ("language", "character.bubble"),
    ("code", "chevron.left.forwardslash.chevron.right"), ("music", "music.note"),
    ("art", "paintbrush"), ("camera", "camera"), ("money", "banknote"),
    ("clean", "sparkles"), ("plant", "camera.macro"), ("pet", "pawprint"),
    ("call", "phone"), ("family", "person.2"), ("heart", "heart"),
    ("pray", "hands.sparkles"), ("focus", "scope"), ("no-phone", "iphone.slash"),
    ("no-smoking", "nosign"), ("no-alcohol", "wineglass"), ("no-sugar", "birthday.cake"),
    ("no-tv", "tv.slash"),
]

/// A habit's icon is either one of the symbols above (stored by its key)
/// or any single emoji, stored as itself.
func isEmojiIcon(_ icon: String) -> Bool {
    guard icon.count == 1, !habitSymbols.contains(where: { $0.key == icon }),
        let first = icon.unicodeScalars.first
    else { return false }
    // Emoji drawn as pictures by default, or text-style ones (like ☀) made
    // into pictures by a following selector or joiner.
    return first.properties.isEmojiPresentation
        || (first.properties.isEmoji && icon.unicodeScalars.count > 1)
}

/// The last emoji in some typed text, if any: used when someone types or
/// pastes an emoji as a habit's icon.
func lastEmoji(in text: String) -> String? {
    text.reversed().map(String.init).first(where: isEmojiIcon)
}

func symbol(for icon: String) -> String {
    habitSymbols.first { $0.key == icon }?.symbol ?? "checkmark.circle"
}

extension Habit {
    var tint: Color { Color(argb: color) }
    var symbolName: String { symbol(for: icon) }
}

/// A habit's icon on a soft circle of its colour.
struct HabitIcon: View {
    let icon: String
    let color: Int
    var size: CGFloat = 36

    var body: some View {
        HabitGlyph(icon: icon, color: color, size: size * 0.46)
            .frame(width: size, height: size)
            .background(Color(argb: color).opacity(0.16), in: .circle)
            .accessibilityHidden(true)
    }
}

/// Just the icon: a symbol in the habit's colour, or the emoji itself.
struct HabitGlyph: View {
    let icon: String
    let color: Int
    var size: CGFloat = 17

    var body: some View {
        if isEmojiIcon(icon) {
            Text(icon).font(.system(size: size * 1.1))
        } else {
            Image(systemName: symbol(for: icon))
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Color(argb: color))
        }
    }
}

extension View {
    /// Large titles on iPhone and iPad; the Mac has none.
    func largeTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.large)
        #else
        self
        #endif
    }

    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Grouped lists, as in the Settings app.
    func groupedList() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        listStyle(.inset(alternatesRowBackgrounds: false))
        #endif
    }

    /// Plain text entry with no autocorrection or capitals, for addresses
    /// and usernames.
    func plainEntry() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }
}

/// "9:00 PM" (or "21:00"), following the device's settings.
func timeLabel(_ hhmm: String) -> String {
    guard let t = TimeOfDay(hhmm) else { return hhmm }
    return t.date().formatted(date: .omitted, time: .shortened)
}

/// "Mon", "Tue"… for a weekday number (1 = Monday).
func weekdayShort(_ weekday: Int) -> String {
    let symbols = Days.calendar.shortWeekdaySymbols  // starts on Sunday
    return symbols[weekday % 7]
}

/// "M", "T"… for a weekday number (1 = Monday).
func weekdayLetter(_ weekday: Int) -> String {
    Days.calendar.veryShortWeekdaySymbols[weekday % 7]
}

/// "Nov 15".
func shortDate(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).day()) }

/// "5 min", "1 hr", "1 hr 30 min".
func durationLabel(_ minutes: Int) -> String {
    let h = minutes / 60, m = minutes % 60
    return [h > 0 ? "\(h) hr" : nil, m > 0 || h == 0 ? "\(m) min" : nil].compactMap { $0 }.joined(separator: " ")
}

/// "5 of 7 days", or "5 of 7 days clear" for a habit being broken.
func daysLabel(_ h: Habit, _ done: Int, _ due: Int) -> String {
    "\(done) of \(due) day\(due == 1 ? "" : "s")\(h.isQuit ? " clear" : "")"
}

extension StrengthLevel {
    var color: Color {
        switch self {
        case .strong: .green
        case .struggling: .red
        default: .secondary
        }
    }
}

/// The line under a habit's name: its version for now and its cue
/// ("Read one page · After I pour coffee · 9:00 PM"). After today's
/// check-in, the reward takes its place.
@MainActor
func detailLine(_ h: Habit, repo: Repo, includeTime: Bool = true) -> String {
    let plan = h.plan
    if !h.isQuit && !plan.reward.isEmpty && repo.isDone(h.id, repo.today) {
        return "Reward: \(plan.reward)"
    }
    return [
        h.isQuit ? "" : plan.twoMinute,
        plan.stackAfter.isEmpty ? "" : "After I \(plan.stackAfter)",
        plan.time.isEmpty || !includeTime ? "" : timeLabel(plan.time),
        plan.location,
    ].filter { !$0.isEmpty }.joined(separator: " · ")
}

/// "Read one page → Read 5 pages → Read 10 pages": how the habit has grown
/// (the last three versions).
func versionHistory(_ plan: HabitPlan) -> String? {
    let versions = plan.sizeHistory.map(\.text)
    guard versions.count > 1 else { return nil }
    let shown = versions.count > 3 ? ["…"] + versions.suffix(3) : versions
    return shown.joined(separator: " → ")
}

/// How "start small and grow it" works, in one place so the editor and the
/// setup wizard say the same thing. Matches `Repo.sizeSuggestion`.
let buildUpExplanation = """
    Start with a version so small you can't say no, like reading one page. Every two weeks, \
    you'll get a quick check-in. If you've been doing it most days, you'll be asked whether \
    it's starting to feel too easy, and you can make it a bit bigger if you like. If you've \
    been missing it a lot, you'll get the option to make it smaller for a while. You can \
    always keep it as it is, or say the size feels right.

    For a daily habit, "most days" means 12 out of 14. For one you do 3 times a week, it's 5 out of 6.
    """

/// A text field with its hint inside it, like "Habit, e.g. Read": the hint
/// disappears as you type, and your text starts on the left. In a Mac form a
/// plain TextField shows its title as a label on the left instead, so typing
/// lands on the far right of the row.
struct HintField: View {
    let hint: String
    @Binding var text: String
    var axis: Axis = .horizontal

    init(_ hint: String, text: Binding<String>, axis: Axis = .horizontal) {
        self.hint = hint
        _text = text
        self.axis = axis
    }

    var body: some View {
        TextField(hint, text: $text, prompt: Text(hint), axis: axis)
            .labelsHidden()
            .multilineTextAlignment(.leading)
    }
}
