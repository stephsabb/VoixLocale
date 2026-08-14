// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "VoixLocale",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "VoixLocale", targets: ["VoixLocale"])],
    targets: [
        .executableTarget(
            name: "VoixLocale",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("PDFKit")
            ]
        ),
        .testTarget(name: "VoixLocaleTests", dependencies: ["VoixLocale"])
    ]
)
