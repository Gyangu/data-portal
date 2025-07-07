// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DataPortal",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .watchOS(.v10),
        .tvOS(.v17),
        .visionOS(.v1)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "DataPortal",
            targets: ["DataPortal"]
        ),
        .library(
            name: "DataPortalSharedMemory", 
            targets: ["DataPortalSharedMemory"]
        ),
        .library(
            name: "DataPortalNetwork",
            targets: ["DataPortalNetwork"]
        ),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/Flight-School/MessagePack.git", from: "1.2.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "DataPortal",
            dependencies: [
                "DataPortalSharedMemory",
                "DataPortalNetwork",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
            ]
        ),
        .target(
            name: "DataPortalSharedMemory",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "DataPortalNetwork", 
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "MessagePack", package: "MessagePack"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "DataPortalTests",
            dependencies: [
                "DataPortal",
                "DataPortalSharedMemory", 
                "DataPortalNetwork",
            ]
        ),
        .executableTarget(
            name: "DataPortalExample",
            dependencies: [
                "DataPortal",
                "DataPortalSharedMemory",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "SwiftSwiftBenchmark",
            dependencies: [
                "DataPortal",
                "DataPortalSharedMemory",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "RustSwiftBenchmark",
            dependencies: [
                "DataPortal",
                "DataPortalSharedMemory",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ]
)