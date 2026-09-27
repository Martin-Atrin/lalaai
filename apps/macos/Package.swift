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
    ]
)
