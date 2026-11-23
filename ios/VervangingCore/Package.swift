// swift-tools-version: 6.2
// The rules package of the native app (ADR-003): pure Swift, imports only Foundation, so its tests run without a
// simulator. The app links the VervangingCore library as a local package; vervanging-sim is the command-line runner
// that grows into the Swift twin of scripts/sim.mjs.
import PackageDescription

let package = Package(
    name: "VervangingCore",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "VervangingCore", targets: ["VervangingCore"]),
        .executable(name: "vervanging-sim", targets: ["vervanging-sim"]),
    ],
    targets: [
        .target(name: "VervangingCore"),
        .executableTarget(name: "vervanging-sim", dependencies: ["VervangingCore"]),
        .testTarget(name: "VervangingCoreTests", dependencies: ["VervangingCore"]),
    ]
)
