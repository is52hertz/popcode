// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "popcode",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "popcode",
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embeds Info.plist so the bare executable has a bundle identifier.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", "\(Context.packageDirectory)/Sources/popcode/Info.plist"])
            ]
        )
    ]
)
