// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Glosa",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "GlosaCore", path: "Sources/GlosaCore"),
        .executableTarget(name: "Glosa", dependencies: ["GlosaCore"], path: "Sources/Glosa"),
        .testTarget(name: "GlosaTests", dependencies: ["GlosaCore"], path: "Tests/GlosaTests"),
    ]
)
