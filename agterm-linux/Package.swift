// swift-tools-version:6.0
import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vendor = "\(packageRoot)/vendor/ghostty"

/// The WebKitGTK plugin behind HTML overlays builds only where webkitgtk-6.0 is installed, so a checkout
/// without it still builds an app that refuses those overlays. Packaging requires the plugin.
let buildsWebKitPlugin: Bool = {
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    probe.arguments = ["pkg-config", "--exists", "webkitgtk-6.0"]
    guard (try? probe.run()) != nil else { return false }
    probe.waitUntilExit()
    return probe.terminationStatus == 0
}()

let webKitProducts: [Product] = buildsWebKitPlugin
    ? [.library(name: "agterm-webkit", type: .dynamic, targets: ["AgtermWebKit"])] : []
let webKitTargets: [Target] = buildsWebKitPlugin ? [
    .systemLibrary(name: "CWebKit", path: "Sources/CWebKit", pkgConfig: "webkitgtk-6.0"),
    .target(name: "AgtermWebKit", dependencies: ["CWebKit"], path: "Sources/AgtermWebKit"),
] : []

let package = Package(
    name: "agterm-linux",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "AgtermLinux", targets: ["AgtermLinux"]),
        .executable(name: "agtermctl-linux", targets: ["agtermctlLinux"]),
        .library(name: "LinuxIntegrations", targets: ["LinuxIntegrations"]),
    ] + webKitProducts,
    dependencies: [
        .package(name: "agtermCore", path: "../agtermCore"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .systemLibrary(name: "CGtk", path: "Sources/CGtk", pkgConfig: "libadwaita-1"),
        .target(
            name: "LinuxIntegrations",
            dependencies: [.product(name: "agtermCore", package: "agtermCore")]
        ),
        .executableTarget(
            name: "AgtermLinux",
            dependencies: [
                "CGtk",
                "LinuxIntegrations",
                .product(name: "agtermCore", package: "agtermCore"),
            ],
            swiftSettings: [ .unsafeFlags(["-Xcc", "-I\(vendor)/include"]) ],
            linkerSettings: [ .unsafeFlags([
                "-L\(vendor)/lib", "-lghostty", "-lepoxy",
                "-Xlinker", "-rpath", "-Xlinker", "\(vendor)/lib",
            ]) ]
        ),
        .executableTarget(
            name: "agtermctlLinux",
            dependencies: [
                "LinuxIntegrations",
                .product(name: "agtermctlKit", package: "agtermCore"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/agtermctl"
        ),
        .testTarget(
            name: "LinuxIntegrationsTests",
            dependencies: ["LinuxIntegrations", .product(name: "agtermCore", package: "agtermCore")]
        ),
        .testTarget(
            name: "agtermctlLinuxTests",
            dependencies: ["agtermctlLinux", "LinuxIntegrations",
                           .product(name: "agtermCore", package: "agtermCore"),
                           .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .testTarget(
            name: "AgtermLinuxTests",
            // CGtk (+ the ghostty header path its umbrella pulls in) so the GLib timer seam can be pumped
            // headlessly with `g_main_context_iteration` — no display and no gtk_init needed.
            dependencies: ["AgtermLinux", "CGtk", .product(name: "agtermCore", package: "agtermCore")],
            swiftSettings: [ .unsafeFlags(["-Xcc", "-I\(vendor)/include"]) ]
        ),
    ] + webKitTargets,
    swiftLanguageModes: [.v6]
)
