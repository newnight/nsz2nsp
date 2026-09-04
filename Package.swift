// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "nszcli",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "Czstd",
            path: "Sources/Czstd",
            cSettings: [
                .define("ZSTD_DISABLE_ASM"),
                .unsafeFlags(["-O2"]),
            ]
        ),
        .target(
            name: "NszCore",
            dependencies: ["Czstd"],
            path: "Sources/NszCore"
        ),
        .executableTarget(
            name: "nszcli",
            dependencies: ["NszCore"],
            path: "Sources/nszcli"
        ),
        .executableTarget(
            name: "nszgui",
            dependencies: ["NszCore"],
            path: "Sources/nszgui"
        )
    ]
)
