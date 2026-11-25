import Testing

@testable import HabitsCore

@Suite struct FocusEndingText {
    @Test func saysWhatJustEnded() {
        #expect(FocusEnding.menuBarText(wasFocus: true, elapsed: 0) == "Time's up")
        #expect(FocusEnding.menuBarText(wasFocus: false, elapsed: 59) == "Break's over")
    }

    @Test func goesAwayAfterAMinute() {
        #expect(FocusEnding.menuBarText(wasFocus: true, elapsed: 60) == nil)
        #expect(FocusEnding.menuBarText(wasFocus: false, elapsed: 600) == nil)
    }
}
