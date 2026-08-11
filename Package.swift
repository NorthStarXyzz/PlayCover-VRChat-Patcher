// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PlayCoverVRChatPatcher",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "PCVRPatcherCore",
            targets: ["PCVRPatcherCore"]
        ),
        .executable(
            name: "PlayCoverVRChatPatcher",
            targets: ["PCVRPatcherApp"]
        ),
        .executable(
            name: "pcvr-manifest-tool",
            targets: ["PCVRManifestTool"]
        )
    ],
    targets: [
        .target(
            name: "PCVRPatcherCore",
            path: "Patcher/Sources/PCVRPatcherCore"
        ),
        .executableTarget(
            name: "PCVRPatcherApp",
            dependencies: ["PCVRPatcherCore"],
            path: "Patcher/Sources/PCVRPatcherApp"
        ),
        .executableTarget(
            name: "PCVRManifestTool",
            dependencies: ["PCVRPatcherCore"],
            path: "Tools/ManifestTool"
        ),
        .testTarget(
            name: "PCVRPatcherTests",
            dependencies: ["PCVRPatcherCore"],
            path: "Tests/Patcher"
        )
    ]
)
