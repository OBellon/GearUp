// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GearUp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GearUpCore", targets: ["GearUpCore"]),
        .executable(name: "GearUp", targets: ["GearUpApp"]),
        .executable(name: "GearUpProbe", targets: ["GearUpProbe"]),
        .executable(name: "GearUpChecks", targets: ["GearUpChecks"]),
    ],
    targets: [
        // Shared, testable core: BLE, protocol codecs and shifting logic.
        .target(
            name: "GearUpCore"
        ),

        // Native SwiftUI app. Packaged into GearUp.app by scripts/build-app.sh.
        .executableTarget(
            name: "GearUpApp",
            dependencies: ["GearUpCore"]
        ),

        // Phase 0 diagnostic tool. It scans for the Zwift Click V2, performs the
        // handshake and dumps every notification so the button masks can be
        // confirmed against real hardware.
        //
        // It must be run from an app bundle so macOS attributes the Bluetooth
        // permission to the probe itself; `make probe` takes care of that.
        .executableTarget(
            name: "GearUpProbe",
            dependencies: ["GearUpCore"]
        ),

        // Unit checks for GearUpCore.
        //
        // XCTest ships with Xcode, which GearUp deliberately does not require:
        // the project is built with the Command Line Tools alone. This target
        // is therefore a small dependency-free runner. Use `make test`.
        .executableTarget(
            name: "GearUpChecks",
            dependencies: ["GearUpCore"]
        ),
    ]
)
