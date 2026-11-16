import Foundation

@testable import HabitsCore

/// The repository's shared test data in fixtures/, also read by the Dart
/// and JavaScript tests, so every implementation is held to the same
/// answers. Found by walking up from this file to the repository root.
func fixture(_ name: String) throws -> [String: JSONValue] {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: dir.appending(path: "fixtures").path) {
        let parent = dir.deletingLastPathComponent()
        guard parent != dir else { throw CocoaError(.fileNoSuchFile) }
        dir = parent
    }
    let data = try Data(contentsOf: dir.appending(path: "fixtures/\(name)"))
    return try JSONDecoder().decode([String: JSONValue].self, from: data)
}
