# Windows

What the Windows app is built from besides its sources in `Sources/NativeHarnessClient/WinUI/` and
`Sources/NativeHarnessClient/Platform/Windows/` (docs/PLATFORM_PORTABILITY.md, "The Windows app"):

| Path | What it is |
| --- | --- |
| `Bindings/projections.json` | The WinUI types the app uses, and the Microsoft packages, with their SHA-512 hashes, their bindings are generated from |
| `Bindings/swift-winrt.json` | The swift-winrt commit that generates the bindings |
| `Bindings/Package.swift`, `Bindings/Sources/` | The bindings as Swift modules linked into the app, the bootstrapper's link, and `XamlApplication`, the application type the app derives from |
| `scripts/generate-bindings.ps1` | Builds swift-winrt, restores the packages and generates the bindings into `Bindings/Generated/`, which git ignores |
| `scripts/place-bootstrapper.ps1` | Puts the Windows App SDK's bootstrapper beside the app's executable |
| `scripts/check-window.ps1` | Opens a build, measures its memory, idle processor time and what it loads, and types Korean into its composer through the Microsoft Korean IME |
| `scripts/install-swift.ps1`, `scripts/install-windows-app-runtime.ps1`, `scripts/report.ps1` | The CI runner's Swift and Windows App Runtime, and a run's annotations |
