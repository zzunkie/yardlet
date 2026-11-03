# Yardlet for iPhone

The phone remote for iOS: it follows the tasks Yardlet runs on your Mac and answers them from the phone, over the
remote protocol ([docs/REMOTE_PROTOCOL.md](../../docs/REMOTE_PROTOCOL.md)). The Mac keeps every agent, sign-in and
session; the phone lists the tasks with the sidebar's marks, reads a task's conversation as it streams, sends
messages (into a running turn or queued after it), answers approvals, questions, plan reviews, MCP forms and browser
handoffs with the Mac card's own choices, stops a turn, starts a task with the Mac's choices, changes a task's model,
effort and permission mode, and pins or archives tasks. It notifies you while it is closed.

It is a SwiftUI app for iOS 17 and later. It builds `YardletRemote`, the package target the Mac's own remote is
built from, so the protocol's types, the Noise channel, pairing links, the race between the same network, Tailscale
and the relay, and the store of a conversation's items are the Mac's code, not a second copy.

## Build and run

Building needs Xcode 27.1 or later. Open `Apps/iOS/Yardlet.xcodeproj`, or from the repository root:

```bash
xcodebuild -project Apps/iOS/Yardlet.xcodeproj -scheme Yardlet \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The project uses the repository's package by its path and the versions in the root `Package.resolved`; its own
copy in `Yardlet.xcodeproj/project.xcworkspace` keeps the same pins. CI builds it when the app or `YardletRemote`
changes (`.github/workflows/ios.yml`).

**Without a Mac:** "Try Without a Mac" on the first screen serves the fixture Mac (docs/REMOTE_PROTOCOL.md §17) inside
the app on loopback and connects to it through the same pairing, handshake and screens as a real Mac. Nothing leaves
the phone, and nothing of it is kept.

**With the fixture on this Mac:** the Simulator shares the Mac's loopback, so the fixture server reaches it directly:

```bash
swift run --build-system native yardlet-remote-fixture
```

Paste the pairing URL it prints into "Paste a Pairing Link", or open it in the Simulator with
`xcrun simctl openurl booted '<pairing URL>'`.

**Screens without touching them:** a debug build reads launch arguments for screenshots and checks: `-demo YES` starts
the demo, `-openTask <task ID>` opens a task, and `-sheet newTask`, `-sheet settings` or `-sheet taskSettings` opens
that sheet, and `-openLink '<pairing link>'` opens a link as another app would, for example:

```bash
xcrun simctl launch booted com.zzunkie.yardlet.remote -demo YES -openTask 0F1E0001-0000-4000-8000-000000000001
```

## Layout

| folder | |
|---|---|
| `Yardlet/` | the app: `Model/` (the paired Macs, one Mac's session, a conversation, discovery, the demo Mac, App Lock) and `Views/` |
| `NotificationService/` | the Notification Service Extension that opens a push |
| `Shared/` | what both targets use: the Keychain and how a push becomes a notification |
| `Config/` | Info.plist additions and entitlements |

## Connections and storage

- A Mac is paired by its QR code (the camera) or its link, pasted or opened from another app; a link from outside
  the app is confirmed first.
- The phone's key for each Mac is in the Keychain, on this device only and never in a backup; the list of Macs
  (their public keys, addresses and relay room) is in Application Support, also left out of backups.
- Only the Mac on screen is connected, and only while the app is in front: iOS suspends an app in the background, and
  the Mac pushes to a phone only while it holds no connection from it.
- The same network is found with Bonjour (`_yardlet._tcp`, which asks for Local Network access once), next to the
  addresses the Mac named and the relay. `NSAllowsLocalNetworking` and the `ts.net` exception let the WebSocket reach
  a Mac's direct address without TLS; the Noise handshake authenticates the Mac by its key on every path.

## Notifications

The Mac seals each push for this phone with the push key it made when the phone registered (§15.6, §16). The app
registers its APNs token with `provider` `apns` (TestFlight and App Store builds) or `apns-sandbox` (a build signed
for development, read from its provisioning profile), and keeps the push key in the Keychain group it shares with the
extension. The relay sends an urgent push as an alert with `mutable-content`; the extension opens it with the key its
`k` names and shows the task, what waits and the Mac's name, or keeps the app's own fallback words when it cannot.
A push that only withdraws a notice is a background push the app reads to remove that task's notifications. The relay
needs the APNs key to send any of this (relay/README.md).

## Signing

The project signs automatically with the team that `Apps/iOS/Signing.local.xcconfig` names (`DEVELOPMENT_TEAM = …`;
git ignores the file, see `Signing.xcconfig`). The app is `com.zzunkie.yardlet.remote` with
Push Notifications and the Keychain group `com.zzunkie.yardlet.remote`; the extension is
`com.zzunkie.yardlet.remote.NotificationService` with the same Keychain group. An unsigned Simulator build runs
without either: it keeps its keys in its own Keychain group and gets no pushes.
