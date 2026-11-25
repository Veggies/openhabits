import Foundation

/// The note shown for a little while once a focus session or break is over.
public enum FocusEnding {
    /// How long the note stays before it goes away by itself.
    public static let showsFor: TimeInterval = 60

    /// - Parameter wasFocus: true after a focus session, false after a break.
    /// - Returns: what the menu bar says, or nil once the note has gone.
    public static func menuBarText(wasFocus: Bool, elapsed: TimeInterval) -> String? {
        guard elapsed < showsFor else { return nil }
        return wasFocus ? "Time's up" : "Break's over"
    }
}
