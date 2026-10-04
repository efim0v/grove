// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Grove",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "GroveCore", targets: ["GroveCore"]),
        .executable(name: "grove", targets: ["grove-cli"]),
        .executable(name: "GroveApp", targets: ["GroveApp"]),
    ],
    targets: [
        .target(
            name: "GroveCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "grove-cli",
            dependencies: ["GroveCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "GroveAppKit",
            dependencies: ["GroveCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "GroveApp",
            dependencies: ["GroveAppKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GroveCoreTests",
            dependencies: ["GroveCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GroveAppKitTests",
            dependencies: ["GroveAppKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
