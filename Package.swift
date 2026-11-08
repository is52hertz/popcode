// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "popcode",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "popcode",
            // Bundled into popcode.app by scripts/bundle.sh.
            exclude: ["Info.plist"]
        )
    ]
)
