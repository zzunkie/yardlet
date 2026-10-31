// swift-tools-version: 6.2

import Foundation
import PackageDescription

// The WinUI bindings of the Windows app (docs/PLATFORM_PORTABILITY.md, "The Windows app"), which the
// repository's manifest depends on when it builds the app on Windows. Windows/scripts/
// generate-bindings.ps1 generates them into Generated/ with swift-winrt: the C ABI module CWinRT, and a
// Swift module for each group of namespaces swift-winrt names (WindowsFoundation for
// Windows.Foundation, UWP for the rest of Windows, WinAppSDK for Microsoft outside XAML, WinUI for
// XAML). CWindowsAppSDK links the Windows App SDK's bootstrapper, CMainQueue declares libdispatch's
// main queue hooks, and WinUIApplication is the hand-written application type the app derives from.
// The libraries are linked into the executable, so the app carries no DLLs of them.
let generated = Context.packageDirectory + "/Generated"
guard FileManager.default.fileExists(atPath: "\(generated)/CWinRT") else {
    fatalError("The WinUI bindings have not been generated: run Windows/scripts/generate-bindings.ps1")
}
let modules = ["WindowsFoundation", "UWP", "WinAppSDK", "WinUI", "WebView2Core"].filter {
    FileManager.default.fileExists(atPath: "\(generated)/\($0)")
}

// swift-winrt writes Swift 5 code. A release build optimizes the generated modules for size and leaves
// out their reflection metadata, which only Mirror and debuggers read: a first window measured 50 MB of
// executable rather than 59 MB, and worked the same.
let generatedSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .unsafeFlags(["-Osize", "-Xfrontend", "-disable-reflection-metadata"], .when(configuration: .release))
]

// Each module may use the ones before it in `modules`, as swift-winrt's modules do.
let moduleTargets: [Target] = modules.enumerated().map { index, name in
    .target(
        name: name,
        dependencies: ["CWinRT"] + modules.prefix(index).map { .target(name: $0) },
        path: "Generated/\(name)",
        swiftSettings: generatedSettings
    )
}

let package = Package(
    name: "WinUIBindings",
    products: [
        .library(name: "WinUIBindings", targets: modules + ["WinUIApplication"])
    ],
    targets: moduleTargets + [
        .target(name: "CWinRT", path: "Generated/CWinRT"),
        .target(
            name: "CWindowsAppSDK",
            path: "Generated/CWindowsAppSDK",
            exclude: ["bin", "lib"],
            linkerSettings: [
                .linkedLibrary("Microsoft.WindowsAppRuntime.Bootstrap"),
                .unsafeFlags(["-L", "\(generated)/CWindowsAppSDK/lib"])
            ]
        ),
        .target(name: "CMainQueue", linkerSettings: [.linkedLibrary("dispatch")]),
        .target(
            name: "WinUIApplication",
            dependencies: ["CMainQueue", "CWindowsAppSDK"] + modules.map { .target(name: $0) },
            swiftSettings: generatedSettings
        )
    ]
)
