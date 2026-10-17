// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PDFToolkitCore",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "PDFToolkitCore", targets: ["PDFToolkitCore"]),
    ],
    targets: [
        .target(
            name: "PDFToolkitCore",
            path: "Sources/PDFToolkitCore"
        ),
        .testTarget(
            name: "PDFToolkitCoreTests",
            dependencies: ["PDFToolkitCore"],
            path: "Tests/PDFToolkitCoreTests",
            // The committed real-PDF corpus (see docs/testing-corpus.md). Copied
            // rather than processed: these are opaque binaries whose exact bytes
            // are the fixture, and SwiftPM's resource processing would be free to
            // rewrite them.
            resources: [.copy("Corpus")]
        ),
    ]
)
