import SwiftUI

/// What the Simulator tab shows for a missing part: what is missing and what to do, with Install where Yardlet can get
/// it (`SimulatorInstalls`). Install reads the download first; the tab shows its size and the licenses to accept, and
/// only Download starts it, with progress and Cancel. Without Xcode, the button opens Xcode's App Store page instead.
struct SimulatorMissingPart: View {
    let platform: SimulatorPlatform
    let check: SimulatorPlatformCheck
    let installs: SimulatorInstalls
    let openURL: @MainActor (URL) -> Void

    var body: some View {
        switch installs.state(of: platform) {
        case .idle, .offered(.openStore):
            missing
        case .preparing:
            VStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text(L10n.string("Checking the download…")).font(.callout).foregroundStyle(.secondary)
            }
        case let .offered(.download(name, bytes, licenses)):
            offer(name: name, bytes: bytes, licenses: licenses)
        case let .installing(name, progress):
            installing(name: name, progress: progress)
        case let .failed(message):
            WorkSurfaceEmptyState(title: L10n.string("The install didn't finish."), message: message,
                                  systemName: "exclamationmark.triangle") {
                Button(L10n.string("Try Again")) { prepare() }.controlSize(.small)
            }
        }
    }

    private var missing: some View {
        let text = SimulatorUnavailableText(check.availability)
        return WorkSurfaceEmptyState(title: text.title, message: text.message, systemName: "iphone.slash") {
            SimulatorInstallButton(platform: platform, check: check, installs: installs, openURL: openURL)
        }
    }

    /// Whether the install has gone past Install, so it shows instead of what is missing.
    static func isUnderWay(_ state: SimulatorInstalls.State) -> Bool {
        switch state {
        case .idle, .offered(.openStore): false
        case .preparing, .offered(.download), .installing, .failed: true
        }
    }

    @ViewBuilder
    private func offer(name: String, bytes: Int64?, licenses: [SimulatorLicense]) -> some View {
        let source = platform == .iOS ? "Apple" : "Google"
        let size = bytes.map { L10n.format("Downloads %@ from %@.", Self.size($0), source) }
            ?? L10n.format("Downloads it from %@.", source)
        if licenses.isEmpty {
            WorkSurfaceEmptyState(title: L10n.format("Install %@?", name), message: size, systemName: "arrow.down.circle") {
                HStack(spacing: 8) {
                    Button(L10n.string("Cancel")) { installs.cancel(platform) }
                    Button(L10n.string("Download")) { installs.confirm(platform, check: check) }
                }
                .controlSize(.small)
            }
        } else {
            VStack(spacing: 10) {
                Text(L10n.format("Install %@?", name)).font(.callout.weight(.semibold))
                Text(size + " " + L10n.string("Read and accept the license to continue."))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                ScrollView {
                    Text(licenses.map(\.text).joined(separator: "\n\n"))
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 320)
                .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(L10n.string("License"))
                HStack(spacing: 8) {
                    Button(L10n.string("Cancel")) { installs.cancel(platform) }
                    Button(L10n.string("Accept and Download")) { installs.confirm(platform, check: check) }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: 460)
            .padding(16)
        }
    }

    private func installing(name: String, progress: SimulatorInstallProgress) -> some View {
        VStack(spacing: 9) {
            Text(progress.stage == .downloading ? L10n.format("Downloading %@…", name) : L10n.format("Installing %@…", name))
                .font(.callout)
                .multilineTextAlignment(.center)
            if let fraction = progress.fraction {
                ProgressView(value: fraction).frame(width: 220)
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else {
                ProgressView().controlSize(.small)
            }
            Button(L10n.string("Cancel")) { installs.cancel(platform) }.controlSize(.small).padding(.top, 4)
        }
        .padding(16)
    }

    private func prepare() {
        installs.prepare(platform, check: check, openURL: openURL)
    }

    nonisolated static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Install, or Open App Store without Xcode, where Yardlet can get what is missing.
struct SimulatorInstallButton: View {
    let platform: SimulatorPlatform
    let check: SimulatorPlatformCheck
    let installs: SimulatorInstalls
    let openURL: @MainActor (URL) -> Void

    var body: some View {
        if installs.offersInstall(for: platform, check: check) {
            Button(check.availability == .xcodeMissing ? L10n.string("Open App Store") : L10n.string("Install")) {
                installs.prepare(platform, check: check, openURL: openURL)
            }
            .controlSize(.small)
        }
    }
}
