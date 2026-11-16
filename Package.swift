// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SuperCopy",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SuperCopy", targets: ["SuperCopy"]),
               .executable(name: "SuperCopyDiagnostics", targets: ["SuperCopyDiagnostics"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "SuperCopyCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "SuperCopy", dependencies: ["SuperCopyCore"]),
        .executableTarget(name: "SuperCopyDiagnostics", dependencies: ["SuperCopyCore"]),
        .testTarget(name: "SuperCopyCoreTests", dependencies: ["SuperCopyCore"])
    ],
    swiftLanguageModes: [.v5]
)
