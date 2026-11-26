// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BeanKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "BeanKit", targets: ["BeanKit"]),
        .executable(name: "beanpod", targets: ["beanpod"]),
    ],
    targets: [
        .target(name: "BeanKit"),
        .executableTarget(name: "beanpod", dependencies: ["BeanKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "BeanKitTests", dependencies: ["BeanKit"], resources: [.copy("Fixtures")]),
    ]
)
