// swift-tools-version: 6.2

import PackageDescription

// The in-window browser runs Chromium (CEF) in a separate browser host process; Yardlet itself
// never loads CEF (docs/BROWSER_HOST.md). The host and CEF helper compile only when YARDLET_CEF_DIR
// names an unpacked CEF distribution, which scripts/build-app.sh verifies and sets. The framework is
// loaded at run time, so nothing links against CEF and a checkout without it builds and tests as
// before, with the WebKit preview in the browser panel.
let cefDirectory = Context.environment["YARDLET_CEF_DIR"].flatMap { $0.isEmpty ? nil : $0 }
let cefCSettings: [CSetting] = cefDirectory.map {
    [.unsafeFlags(["-I", $0]), .define("CEF_API_VERSION", to: "15400")]
} ?? []
let cefTargets: [Target] = cefDirectory == nil ? [] : [
    .target(
        name: "YardletCEFBridge",
        path: "Sources/YardletCEFBridge",
        cSettings: cefCSettings,
        linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("IOSurface")]
    ),
    .executableTarget(
        name: "YardletCEFHelper",
        path: "Sources/YardletCEFHelper",
        cSettings: cefCSettings
    ),
    .executableTarget(
        name: "YardletBrowserHost",
        dependencies: ["YardletCEFBridge", "YardletSurfacePort", "YardletCEFAccessibility"],
        path: "Sources/YardletBrowserHost",
        linkerSettings: [.linkedFramework("Metal")]
    )
]

// The engine is every folder of the app target outside the screen and macOS layers
// (docs/PLATFORM_PORTABILITY.md). With YARDLET_ENGINE_ONLY=1 the app target compiles the engine alone,
// as a library without the macOS layers and their dependencies: the build that Windows makes, and the
// check that the engine still stands on its own.
let engineOnly = Context.environment["YARDLET_ENGINE_ONLY"] == "1"
let macOSLayers = ["Views", "Browser", "Development", "Platform/macOS", "NativeHarnessClientApp.swift"]
// Platform/Portable holds Foundation versions of what each platform layer provides under the same
// names, for the engine-only build; the Mac app has its own in Platform/macOS.
let otherPlatformLayers = ["Platform/Portable"]

// The phone remote's listeners and interface addresses use Network.framework and BSD sockets; a
// build on another platform leaves them out until that platform has its own.
#if os(macOS)
let remoteMacOnlySources: [String] = []
#else
let remoteMacOnlySources = ["RemoteSecureListener.swift", "RemoteAddresses.swift"]
#endif

#if os(Windows)
let sqliteTarget: Target = .target(
    name: "CSQLite",
    path: "Sources/CSQLiteWindows",
    linkerSettings: [.linkedLibrary("winsqlite3")]
)
#else
let sqliteTarget: Target = .systemLibrary(name: "CSQLite")
#endif

let appTarget: Target = engineOnly
    ? .target(
        name: "NativeHarnessClient",
        dependencies: [
            "CSQLite",
            "YardletAgentTools",
            "YardletRemote",
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "Markdown", package: "swift-markdown")
        ],
        exclude: macOSLayers,
        resources: [
            .process("Resources")
        ]
    )
    : .executableTarget(
        name: "NativeHarnessClient",
        dependencies: [
            "CSQLite",
            "YardletAgentTools",
            "YardletLidSleep",
            "YardletRemote",
            .target(name: "YardletSurfacePort", condition: .when(platforms: [.macOS])),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "Markdown", package: "swift-markdown"),
            .product(name: "SwiftTerm", package: "SwiftTerm"),
            .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS]))
        ],
        exclude: otherPlatformLayers,
        resources: [
            .process("Resources")
        ],
        // build-app.sh puts the frameworks SwiftPM links beside the executable (Sparkle) in the
        // bundle's Contents/Frameworks.
        linkerSettings: [
            .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"],
                         .when(platforms: [.macOS]))
        ]
    )

let package = Package(
    name: "NativeHarnessClient",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    products: (engineOnly ? [] : [
        .executable(name: "NativeHarnessClient", targets: ["NativeHarnessClient"])
    ]) + [
        // The Yardlet MCP server a harness starts over stdio; build-app.sh places it in
        // Contents/Helpers. It forwards tool calls to the running app (docs/AGENT_BROWSER_TOOLS.md).
        .executable(name: "yardlet-mcp", targets: ["YardletMCP"]),
        // The launch daemon behind Settings › General › "Keep tasks working with the lid closed";
        // build-app.sh places it in Contents/Helpers beside its launchd property list
        // (docs/REMOTE_V2_DESIGN.md §6.5).
        .executable(name: "yardlet-lid-helper", targets: ["YardletLidHelper"]),
        // The phone remote's fixture server: the remote protocol on loopback with fixture tasks, for
        // building the Android client without real tasks (docs/REMOTE_PROTOCOL.md §9).
        .executable(name: "yardlet-remote-fixture", targets: ["YardletRemoteFixture"])
    ] + (cefDirectory == nil ? [] : [
        .executable(name: "YardletCEFHelper", targets: ["YardletCEFHelper"]),
        .executable(name: "YardletBrowserHost", targets: ["YardletBrowserHost"])
    ]),
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-markdown.git",
            exact: "0.8.0"
        ),
        // CryptoKit's API on every platform: on macOS it re-exports CryptoKit, elsewhere it builds
        // BoringSSL (docs/PLATFORM_PORTABILITY.md).
        .package(
            url: "https://github.com/apple/swift-crypto.git",
            exact: "5.0.3"
        )
    ] + (engineOnly ? [] : [
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            exact: "1.18.0"
        ),
        // Updates for public builds (README "Updates"). A binary target whose checksum Sparkle's
        // own manifest pins; build-app.sh places the framework in Contents/Frameworks, and only a
        // bundle built with a feed URL and key turns it on.
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.10.1"
        )
    ]),
    targets: [
        // macOS supplies SQLite in the SDK and at /usr/lib/libsqlite3.dylib. pkg-config can
        // instead select a local Homebrew copy, which is absent on other Macs and rejected by
        // Developer ID library validation. Use the SDK header and system library in every build.
        // Windows supplies its own SQLite (winsqlite3), with the header in the Windows SDK.
        sqliteTarget,
        // Mach hand-off of IOSurfaces between the browser host and Yardlet (macOS platform layer).
        .target(
            name: "YardletSurfacePort",
            linkerSettings: [
                .linkedFramework("IOSurface", .when(platforms: [.macOS])),
                .linkedLibrary("bsm", .when(platforms: [.macOS]))
            ]
        ),
        // CEF accessibility output → the browser host contract's smaller shape. Foundation only, so
        // the browser host uses it and the tests check it against recorded CEF output without CEF.
        .target(name: "YardletCEFAccessibility"),
        // The MCP protocol, the tool catalog, and the local connection shared by the app and
        // yardlet-mcp. Foundation only outside Platform/, like the app's engine.
        .target(name: "YardletAgentTools"),
        .executableTarget(
            name: "YardletMCP",
            dependencies: ["YardletAgentTools"]
        ),
        // The lid helper's state, its XPC interface and the power readings it shares with the app.
        .target(
            name: "YardletLidSleep",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("Security")]
        ),
        .executableTarget(
            name: "YardletLidHelper",
            dependencies: ["YardletLidSleep"]
        ),
        // The phone remote (docs/REMOTE_PROTOCOL.md): the protocol, pairing and the server, with no
        // UI, and the WebSocket listeners (Network.framework). The app adds the bridge to its model.
        .target(
            name: "YardletRemote",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            exclude: remoteMacOnlySources,
            linkerSettings: [.linkedFramework("Network", .when(platforms: [.macOS]))]
        ),
        // The fixture Mac behind the remote protocol, for the phone client and the remote tests;
        // the app does not link it.
        .target(
            name: "YardletRemoteFixtureSupport",
            dependencies: ["YardletRemote"]
        ),
        .executableTarget(
            name: "YardletRemoteFixture",
            dependencies: [
                "YardletRemote",
                "YardletRemoteFixtureSupport",
                .product(name: "Crypto", package: "swift-crypto")
            ]
        ),
        appTarget
    ] + (engineOnly ? [] : [
        // The tests build against the Mac app, SwiftTerm included.
        .testTarget(
            name: "NativeHarnessClientTests",
            dependencies: [
                "NativeHarnessClient",
                "YardletAgentTools",
                "YardletMCP",
                "YardletLidSleep",
                "YardletRemote",
                "YardletRemoteFixture",
                "YardletRemoteFixtureSupport",
                "CSQLite",
                "YardletCEFAccessibility",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            // Recorded fixtures are read from the source tree, so the target keeps no resource
            // bundle of its own (tests use the app module's `Bundle.module`).
            exclude: ["Fixtures"]
        )
    ]) + cefTargets
)
