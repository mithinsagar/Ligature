// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ligature",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Ligature", targets: ["Ligature"]),
        .library(name: "LigatureCore", targets: ["LigatureCore"]),
    ],
    targets: [
        // Everything that is not UI: log, SyncTeX, outline and BibTeX parsing, tables, symbols, templates. No third-party deps.
        .target(name: "LigatureCore"),
        .executableTarget(name: "Ligature", dependencies: ["LigatureCore"], resources: [.copy("Resources")]),
        .testTarget(name: "LigatureCoreTests", dependencies: ["LigatureCore"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
