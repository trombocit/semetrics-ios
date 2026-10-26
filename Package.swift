// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Semetrics",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "Semetrics", targets: ["Semetrics"]),
    ],
    targets: [
        .target(
            name: "Semetrics",
            path: "Sources/Semetrics"
        ),
        .testTarget(
            name: "SemetricsTests",
            dependencies: ["Semetrics"],
            path: "Tests/SemetricsTests"
        ),
    ]
)
