@preconcurrency import AVFoundation
import SwiftUI
import YardletRemote

/// The camera, reading the pairing code a Mac shows (docs/REMOTE_PROTOCOL.md §12). The first Yardlet pairing link
/// it sees ends the scan; any other code is ignored.
struct PairingScanner: View {
    let onLink: (RemoteSecurePairingURL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                switch access {
                case .authorized:
                    CameraView(onLink: onLink)
                        .ignoresSafeArea()
                    VStack {
                        Spacer()
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                            .frame(width: 240, height: 240)
                        Spacer()
                        Text("Point the camera at the code on your Mac.")
                            .font(.callout)
                            .foregroundStyle(.white)
                            .padding(.bottom, 32)
                    }
                case .notDetermined:
                    ProgressView().tint(.white)
                default:
                    VStack(spacing: 12) {
                        Text("Yardlet can't use the camera.")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("Allow camera access in Settings, or paste the pairing link instead.")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(32)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .task {
            if access == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                access = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }
}

private struct CameraView: UIViewControllerRepresentable {
    let onLink: (RemoteSecurePairingURL) -> Void

    func makeUIViewController(context: Context) -> CameraController {
        let controller = CameraController()
        controller.onLink = onLink
        return controller
    }

    func updateUIViewController(_ controller: CameraController, context: Context) {}
}

private final class CameraController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onLink: ((RemoteSecurePairingURL) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var done = false

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        self.preview = preview
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        let texts = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        MainActor.assumeIsolated {
            guard !done else { return }
            for text in texts {
                if let url = URL(string: text), let link = RemoteSecurePairingURL.parse(url) {
                    done = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onLink?(link)
                    return
                }
            }
        }
    }
}
