// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tabula",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TabulaCore", targets: ["TabulaCore"]),
        .executable(name: "Tabula", targets: ["Tabula"]),
    ],
    targets: [
        .target(name: "TabulaCore"),
        .executableTarget(
            name: "Tabula",
            dependencies: ["TabulaCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(name: "TabulaCoreTests", dependencies: ["TabulaCore"]),
    ]
)
