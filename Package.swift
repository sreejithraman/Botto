// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BottoCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "BottoCore", targets: ["BottoCore"])],
    targets: [
        .target(name: "BottoCore"),
        .testTarget(name: "BottoCoreTests", dependencies: ["BottoCore"], resources: [.copy("Fixtures")])
    ]
)
