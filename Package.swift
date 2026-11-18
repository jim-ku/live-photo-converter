// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LivePhotoConverter",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "LivePhotoConverter", path: "LivePhotoConverter/Sources"),
        .testTarget(name: "LivePhotoConverterTests", dependencies: ["LivePhotoConverter"], path: "Tests")
    ]
)
