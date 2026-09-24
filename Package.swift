// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "seckey-dialog",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "seckey-dialog", targets: ["seckey-dialog"])
    ],
    targets: [
        .target(name: "SeckeyDialogCore"),
        .executableTarget(name: "seckey-dialog", dependencies: ["SeckeyDialogCore"]),
        .testTarget(name: "SeckeyDialogCoreTests", dependencies: ["SeckeyDialogCore"]),
    ]
)
