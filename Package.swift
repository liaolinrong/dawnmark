// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DawnMark",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DawnMark", targets: ["DawnMark"]),
        .library(name: "DawnMarkSupport", targets: ["DawnMarkSupport"]),
        .library(name: "DocumentWorkspace", targets: ["DocumentWorkspace"]),
        .library(name: "MarkdownEngine", targets: ["MarkdownEngine"]),
        .library(name: "EditorKit", targets: ["EditorKit"])
    ],
    dependencies: [
        .package(path: "../appcommerce"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.7.3")
    ],
    targets: [
        .target(name: "DawnMarkSupport", resources: [.process("Resources")]),
        .testTarget(name: "DawnMarkSupportTests", dependencies: ["DawnMarkSupport"]),
        .executableTarget(name: "DawnMark", dependencies: ["DocumentWorkspace", "EditorKit", "DawnMarkSupport", .product(name: "CommerceCore", package: "appcommerce"), .product(name: "CommerceStoreKit", package: "appcommerce")]),
        .target(name: "DocumentWorkspace", dependencies: [.product(name: "Markdown", package: "swift-markdown")]),
        .testTarget(name: "DocumentWorkspaceTests", dependencies: ["DocumentWorkspace"]),
        .target(name: "MarkdownEngine", dependencies: [.product(name: "Markdown", package: "swift-markdown")]),
        .target(name: "EditorKit", dependencies: ["MarkdownEngine"]),
        .testTarget(name: "MarkdownEngineTests", dependencies: ["MarkdownEngine", "EditorKit"])
    ]
)