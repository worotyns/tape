// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tape",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TapeCore", targets: ["TapeCore"]),
        .executable(name: "Tape", targets: ["Tape"]),
    ],
    targets: [
        .target(name: "TapeCore"),
        .executableTarget(
            name: "Tape",
            dependencies: ["TapeCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(name: "TapeCoreTests", dependencies: ["TapeCore"]),
    ]
)
