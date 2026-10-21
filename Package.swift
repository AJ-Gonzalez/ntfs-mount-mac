// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NTFSMount",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NTFSMount", targets: ["NTFSMountApp"]),
        .executable(name: "ntfsmount-helper", targets: ["ntfsmount-helper"]),
    ],
    targets: [
        .target(name: "NTFSMountCore"),
        .executableTarget(name: "NTFSMountApp", dependencies: ["NTFSMountCore"]),
        .executableTarget(name: "ntfsmount-helper", dependencies: ["NTFSMountCore"]),
    ]
)
