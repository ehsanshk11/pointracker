// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pointracker",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Pointracker", targets: ["Pointracker"]),
        .library(name: "PointrackerCore", targets: ["PointrackerCore"]),
    ],
    targets: [
        // Pure decision logic: features, classifier, dwell/hysteresis, pause rules.
        // No AppKit/Vision so it stays unit-testable.
        .target(name: "PointrackerCore"),
        // The menu bar app: camera, Vision, Accessibility, power and lock monitoring.
        .executableTarget(
            name: "Pointracker",
            dependencies: ["PointrackerCore"]
        ),
        .testTarget(
            name: "PointrackerCoreTests",
            dependencies: ["PointrackerCore"]
        ),
    ]
)
