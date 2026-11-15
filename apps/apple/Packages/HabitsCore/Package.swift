// swift-tools-version: 6.2
import PackageDescription

/// The parts of the app that aren't screens: the data model and its rules,
/// the on-device database, and sync with the server. Kept in step with the
/// Dart code in packages/core and apps/client/lib/data, so the Apple and
/// Android apps agree on every rule.
let package = Package(
    name: "HabitsCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "HabitsCore", targets: ["HabitsCore"]),
    ],
    targets: [
        .target(name: "HabitsCore"),
        .testTarget(name: "HabitsCoreTests", dependencies: ["HabitsCore"]),
    ]
)
