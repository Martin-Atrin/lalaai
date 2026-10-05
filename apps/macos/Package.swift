// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "lalaai",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "lalaai",
            path: "Sources/lalaai",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Speech"),
                .linkedFramework("Translation"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Network"),
            ]
        ),
        // The embedded relay (apps/shared/Relay, symlinked) as a CLI: conformance tests run web/relay's suite against it.
        .executableTarget(
            name: "lalaai-relay",
            path: "Sources/lalaai-relay",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Network")]
        ),
        // `swift test`: config migration, tunnel output parsing.
        .testTarget(
            name: "lalaaiTests",
            dependencies: ["lalaai"],
            path: "Tests/lalaaiTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
