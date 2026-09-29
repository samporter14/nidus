// swift-tools-version: 6.2
// Nidus — blocks distracting apps and websites for a set time, from the menu
// bar. Sources/Nidus/Core is the blocking engine (no UI); Sources/Nidus/App is
// the menu bar item, its popover, the cards at the top of the screen, and
// Settings.
import PackageDescription

let package = Package(
    name: "Nidus",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "Nidus",
            path: "Sources/Nidus"
        ),
        .testTarget(
            name: "NidusTests",
            dependencies: ["Nidus"],
            path: "Tests/NidusTests"
        ),
    ]
)
