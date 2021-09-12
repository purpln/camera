// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "Camera",
    platforms: [.iOS(.v10)],
    products: [.library(name: "Camera", targets: ["Camera"])],
    dependencies: [],
    targets: [.target(name: "Camera")]
)
