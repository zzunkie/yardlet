// swift-tools-version: 6.2

import PackageDescription

// Checks how code swift-winrt generates behaves at run time, on the Windows app's bindings
// (docs/PLATFORM_PORTABILITY.md, "The Windows app"): whether string getters release the strings they
// receive, whether a projected object passed where WinRT takes an Object keeps its COM identity, and
// what boxed values come back as. Windows/scripts/run-swift-winrt-probe.ps1 builds and runs it.
let package = Package(
    name: "SwiftWinRTProbe",
    dependencies: [
        .package(path: "../../Bindings")
    ],
    targets: [
        .executableTarget(
            name: "SwiftWinRTProbe",
            dependencies: [.product(name: "WinUIBindings", package: "Bindings")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
