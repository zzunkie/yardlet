import CMainQueue
import CWindowsAppSDK
import Foundation
import WinAppSDK
import WinSDK
import WindowsFoundation
@_spi(WinRTInternal) import WinUI

/// A WinUI application in an unpackaged process, for a window to derive from and mark `@main`.
///
/// `main()` starts COM for the thread and the Windows App Runtime through the Windows App SDK's
/// bootstrapper, creates the application as the type `main()` was called on, and runs the thread's
/// message loop, which also runs Foundation's run loop and the main dispatch queue, where Swift's main
/// actor runs. The application supplies the XAML controls' metadata and styles, as an App.xaml does
/// for a C# application, and calls `launched()` when the window can be made.
open class XamlApplication: Application, IXamlMetadataProvider {
    public enum StartFailure: Swift.Error {
        case call(String, HRESULT)
    }

    public required override init() {
        super.init()
    }

    /// Makes the first window; XAML elements can be made from here on.
    open func launched() {}

    /// Called once the message loop has ended, with its exit code.
    open func shutDown(exitCode: Int32) {}

    override public func onLaunched(_ args: WinUI.LaunchActivatedEventArgs!) throws {
        resources.mergedDictionaries.append(XamlControlsResources())
        launched()
    }

    @MainActor
    public static func main() {
        do {
            try startWindowsAppRuntime()
            // XAML runs on a thread with a dispatcher queue, set up for XAML once the application
            // exists.
            let queue = try DispatcherQueueController.createOnCurrentThread()
            let application = Self()
            let xaml = try WindowsXamlManager.initializeForCurrentThread()
            application.dispatcherShutdownMode = .onLastWindowClose
            let exitCode = withExtendedLifetime((queue, xaml)) { runMessageLoop() }
            application.shutDown(exitCode: exitCode)
        } catch {
            fatalError("The application did not start: \(error)")
        }
    }

    // MARK: IXamlMetadataProvider, through the controls' own provider

    private lazy var controlsMetadata = XamlControlsXamlMetaDataProvider()

    override open func queryInterface(_ iid: WindowsFoundation.IID) -> IUnknownRef? {
        if iid == __ABI_Microsoft_UI_Xaml_Markup.IXamlMetadataProviderWrapper.IID {
            return __ABI_Microsoft_UI_Xaml_Markup.IXamlMetadataProviderWrapper(self)?.queryInterface(iid)
        }
        return super.queryInterface(iid)
    }

    public func getXamlType(_ type: TypeName) throws -> AnyIXamlType! {
        try controlsMetadata.getXamlType(type)
    }

    public func getXamlType(_ fullName: String) throws -> AnyIXamlType! {
        try controlsMetadata.getXamlType(fullName)
    }

    public func getXmlnsDefinitions() throws -> [XmlnsDefinition] {
        try controlsMetadata.getXmlnsDefinitions()
    }

    // MARK: Starting and running

    private static func startWindowsAppRuntime() throws {
        let initialized = RoInitialize(RO_INIT_SINGLETHREADED)
        guard initialized >= 0 else { throw StartFailure.call("RoInitialize", initialized) }
        // The Windows App SDK release the bindings were generated from; a stable release has no tag.
        let result = "".withCString(encodedAs: UTF16.self) { tag in
            MddBootstrapInitialize2(
                UInt32(WINDOWSAPPSDK_RELEASE_MAJORMINOR),
                tag,
                PACKAGE_VERSION(),
                MddBootstrapInitializeOptions_OnNoMatch_ShowUI
            )
        }
        guard result >= 0 else { throw StartFailure.call("MddBootstrapInitialize2", result) }
    }

    /// Lets the Windows App SDK's input handling see a message before it is dispatched.
    private typealias PreTranslate = @convention(c) (UnsafePointer<MSG>?) -> Bool
    private static let preTranslate: PreTranslate? = {
        guard let windowing = LoadLibraryW(Array("Microsoft.UI.Windowing.Core.dll".utf16) + [0]),
              let address = GetProcAddress(windowing, "ContentPreTranslateMessage") else { return nil }
        return unsafeBitCast(address, to: PreTranslate.self)
    }()

    /// The thread's message loop. Between messages it waits for the next one, the main dispatch queue's
    /// event, or Foundation's next timer, whichever comes first, and does no work while nothing comes.
    private static func runMessageLoop() -> Int32 {
        var mainQueue: HANDLE? = _dispatch_get_main_queue_handle_4CF()
        var message = MSG()
        while true {
            while PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) {
                if message.message == UINT(WM_QUIT) { return Int32(message.wParam) }
                if !(preTranslate?(&message) ?? false) {
                    TranslateMessage(&message)
                    DispatchMessageW(&message)
                }
            }
            let next = RunLoop.main.limitDate(forMode: .default)
            let timeout = next.map { DWORD(max(0, min($0.timeIntervalSinceNow * 1000, 3_600_000))) } ?? DWORD(INFINITE)
            let woken = MsgWaitForMultipleObjects(mainQueue == nil ? 0 : 1, &mainQueue, false, timeout, DWORD(QS_ALLINPUT))
            // WAIT_OBJECT_0: the main queue's event, the one handle waited for.
            if mainQueue != nil, woken == 0 {
                _dispatch_main_queue_callback_4CF(nil)
            }
        }
    }
}
