// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TZ Convert Project",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "tzconvert", targets: ["tzconvert"]),
        .library(name: "TimeConvertCore", targets: ["TimeConvertCore"])
    ],
    targets: [
        .target(name: "TimeConvertCore"),
        .executableTarget(
            name: "tzconvert",
            dependencies: ["TimeConvertCore"]
        ),
        .testTarget(
            name: "TimeConvertCoreTests",
            dependencies: ["TimeConvertCore"]
        )
    ]
)
