// swift-tools-version: 5.9
import PackageDescription
let package = Package(
  name: "WindowVM",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "WindowVM", targets: ["WindowVM"])],
  targets: [
    .target(name: "VMCore"),
    .executableTarget(name: "WindowVM", dependencies: ["VMCore"]),
    .testTarget(name: "VMCoreTests", dependencies: ["VMCore"]),
    .testTarget(name: "WindowVMTests", dependencies: ["WindowVM", "VMCore"]),
    .executableTarget(name: "VMSmoke", dependencies: ["VMCore"])
  ]
)
