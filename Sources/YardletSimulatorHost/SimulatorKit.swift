import CoreGraphics
import Darwin
import Foundation
import ObjectiveC

// SimulatorKit and CoreSimulator are Xcode's private frameworks; nothing links against them. The helper opens them
// at run time from the Xcode Yardlet names, so a Mac without Xcode runs Yardlet as before, and checks on start that
// every class, method and function it uses is there. Xcode 27 moved SimulatorKit from Contents/Developer/Library/
// PrivateFrameworks to Contents/SharedFrameworks, so both are looked at, the new place first.

typealias MouseMessageFunction = @convention(c) (UnsafePointer<CGPoint>?, UnsafePointer<CGPoint>?, UInt32, UInt, CGSize, UInt32)
    -> UnsafeMutableRawPointer?
typealias ButtonMessageFunction = @convention(c) (UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
typealias ArbitraryMessageFunction = @convention(c) (UInt32, UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
typealias KeyboardMessageFunction = @convention(c) (UInt32, UInt32) -> UnsafeMutableRawPointer?
typealias DigitizerMessageFunction = @convention(c) (OpaquePointer, UInt32) -> UnsafeMutableRawPointer?
// IOKit's IOHIDEventCreateDigitizerEvent(allocator, timeStamp, transducerType, index, identity, eventMask, buttonMask,
// x, y, z, tipPressure, barrelPressure, range, touch, options) and IOHIDEventCreateDigitizerFingerEvent(allocator,
// timeStamp, index, identity, eventMask, x, y, z, tipPressure, twist, range, touch, options).
typealias CreateDigitizerEventFunction = @convention(c) (
    UnsafeRawPointer?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32,
    Double, Double, Double, Double, Double, UInt8, UInt8, UInt32
) -> OpaquePointer?
typealias CreateFingerEventFunction = @convention(c) (
    UnsafeRawPointer?, UInt64, UInt32, UInt32, UInt32,
    Double, Double, Double, Double, Double, UInt8, UInt8, UInt32
) -> OpaquePointer?
typealias AppendEventFunction = @convention(c) (OpaquePointer, OpaquePointer, UInt32) -> Void

/// IOKit digitizer events wrapped in an Indigo message: the touch path that system layers (Notification Center,
/// Control Center, a folder's backdrop) also take.
struct DigitizerFunctions {
    let createDigitizerEvent: CreateDigitizerEventFunction
    let createFingerEvent: CreateFingerEventFunction
    let appendEvent: AppendEventFunction
    let message: DigitizerMessageFunction
}

enum SimulatorKitLoad {
    case loaded(SimulatorKit)
    case unsupported(xcode: String, missing: [String])
}

final class SimulatorKit: @unchecked Sendable {
    let xcodeVersion: String
    let developerDirectory: String
    let serviceContextClass: AnyClass
    let hidClientClass: AnyClass
    let mouseMessage: MouseMessageFunction
    let buttonMessage: ButtonMessageFunction
    let arbitraryMessage: ArbitraryMessageFunction
    let keyboardMessage: KeyboardMessageFunction
    let digitizer: DigitizerFunctions?

    static let coreSimulatorPath = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"
    static let hidClientClassName = "_TtC12SimulatorKit24SimDeviceLegacyHIDClient"

    /// The selectors called on objects the helper gets from CoreSimulator, by the protocol or class that declares
    /// them. Several of the objects are remote proxies, which answer `responds(to:)` with false, so these are checked
    /// on the protocols' declarations.
    static let protocolMethods: [(protocol: String, selectors: [String])] = [
        ("SimScreen", ["registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:",
                       "unregisterScreenCallbacksWithUUID:", "screenProperties"]),
        ("SimDisplayIOSurfaceRenderable", ["framebufferSurface"]),
        ("SimScreenProperties", ["screenID", "screenType", "pixelSize", "powerState"]),
        ("SimDeviceIOPortInterface", ["descriptor"])
    ]
    static let classMethods: [(class: String, instance: [String], type: [String])] = [
        ("SimServiceContext", ["defaultDeviceSetWithError:"], ["sharedServiceContextForDeveloperDir:error:"]),
        ("SimDeviceSet", ["devicesByUDID"], []),
        ("SimDevice", ["state", "io", "deviceType", "registerNotificationHandlerOnQueue:handler:", "unregisterNotificationHandler:error:"], []),
        ("SimDeviceType", ["mainScreenScale"], []),
        ("SimDeviceIOClient", ["ioPorts"], []),
        (hidClientClassName, ["initWithDevice:error:", "sendWithMessage:freeWhenDone:completionQueue:completion:"], [])
    ]

    private init(xcodeVersion: String, developerDirectory: String, serviceContextClass: AnyClass, hidClientClass: AnyClass,
                 mouseMessage: MouseMessageFunction, buttonMessage: ButtonMessageFunction,
                 arbitraryMessage: ArbitraryMessageFunction, keyboardMessage: KeyboardMessageFunction,
                 digitizer: DigitizerFunctions?) {
        self.xcodeVersion = xcodeVersion
        self.developerDirectory = developerDirectory
        self.serviceContextClass = serviceContextClass
        self.hidClientClass = hidClientClass
        self.mouseMessage = mouseMessage
        self.buttonMessage = buttonMessage
        self.arbitraryMessage = arbitraryMessage
        self.keyboardMessage = keyboardMessage
        self.digitizer = digitizer
    }

    var capabilities: [String] { digitizer == nil ? [] : ["digitizerTouch"] }

    static func load(developerDirectory: String) -> SimulatorKitLoad {
        let developer = URL(fileURLWithPath: developerDirectory, isDirectory: true).standardizedFileURL
        let xcode = xcodeVersion(developerDirectory: developer)
        var missing: [String] = []
        guard dlopen(coreSimulatorPath, RTLD_NOW | RTLD_GLOBAL) != nil else {
            return .unsupported(xcode: xcode, missing: ["CoreSimulator.framework (\(lastError()))"])
        }
        let candidates = [
            developer.deletingLastPathComponent().appending(path: "SharedFrameworks/SimulatorKit.framework/SimulatorKit"),
            developer.appending(path: "Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit")
        ].map { $0.path(percentEncoded: false) }
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return .unsupported(xcode: xcode, missing: ["SimulatorKit.framework"])
        }
        guard let simulatorKit = dlopen(path, RTLD_NOW | RTLD_GLOBAL) else {
            return .unsupported(xcode: xcode, missing: ["SimulatorKit.framework (\(lastError()))"])
        }
        let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

        for (name, selectors) in protocolMethods {
            guard let declared = objc_getProtocol(name) else {
                missing.append("protocol \(name)")
                continue
            }
            for selector in selectors where protocol_getMethodDescription(declared, NSSelectorFromString(selector), true, true).name == nil {
                missing.append("-[\(name) \(selector)]")
            }
        }
        for (name, instance, type) in classMethods {
            guard let found: AnyClass = NSClassFromString(name) else {
                missing.append("class \(name)")
                continue
            }
            for selector in instance where class_getInstanceMethod(found, NSSelectorFromString(selector)) == nil {
                missing.append("-[\(name) \(selector)]")
            }
            for selector in type where class_getClassMethod(found, NSSelectorFromString(selector)) == nil {
                missing.append("+[\(name) \(selector)]")
            }
        }

        func function<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type, required: Bool = true) -> T? {
            guard let handle, let symbol = dlsym(handle, name) else {
                if required { missing.append(name) }
                return nil
            }
            return unsafeBitCast(symbol, to: type)
        }
        let mouse = function(simulatorKit, "IndigoHIDMessageForMouseNSEvent", as: MouseMessageFunction.self)
        let button = function(simulatorKit, "IndigoHIDMessageForButton", as: ButtonMessageFunction.self)
        let arbitrary = function(simulatorKit, "IndigoHIDMessageForHIDArbitrary", as: ArbitraryMessageFunction.self)
        let keyboard = function(simulatorKit, "IndigoHIDMessageForKeyboardArbitrary", as: KeyboardMessageFunction.self)
        // Optional: without them touches go the mouse way, which ordinary views take and system layers do not.
        var digitizer: DigitizerFunctions?
        if let message = function(simulatorKit, "IndigoHIDMessageForTrackpadEventFromHIDEventRef", as: DigitizerMessageFunction.self, required: false),
           let create = function(ioKit, "IOHIDEventCreateDigitizerEvent", as: CreateDigitizerEventFunction.self, required: false),
           let finger = function(ioKit, "IOHIDEventCreateDigitizerFingerEvent", as: CreateFingerEventFunction.self, required: false),
           let append = function(ioKit, "IOHIDEventAppendEvent", as: AppendEventFunction.self, required: false) {
            digitizer = DigitizerFunctions(createDigitizerEvent: create, createFingerEvent: finger, appendEvent: append, message: message)
        }

        guard missing.isEmpty, let mouse, let button, let arbitrary, let keyboard,
              let context: AnyClass = NSClassFromString("SimServiceContext"),
              let hidClient: AnyClass = NSClassFromString(hidClientClassName) else {
            return .unsupported(xcode: xcode, missing: missing)
        }
        return .loaded(SimulatorKit(xcodeVersion: xcode, developerDirectory: developer.path(percentEncoded: false),
                                    serviceContextClass: context, hidClientClass: hidClient, mouseMessage: mouse,
                                    buttonMessage: button, arbitraryMessage: arbitrary, keyboardMessage: keyboard,
                                    digitizer: digitizer))
    }

    /// `27.2 (27B52)`, from the Xcode bundle's version.plist.
    private static func xcodeVersion(developerDirectory: URL) -> String {
        let plist = developerDirectory.deletingLastPathComponent().appending(path: "version.plist")
        guard let data = try? Data(contentsOf: plist),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = values["CFBundleShortVersionString"] as? String else { return "unknown" }
        guard let build = values["ProductBuildVersion"] as? String else { return version }
        return "\(version) (\(build))"
    }

    private static func lastError() -> String {
        dlerror().map { String(cString: $0) } ?? "unknown error"
    }
}

/// Calls to Objective-C methods through their implementations, for the remote proxies CoreSimulator returns: they
/// answer messages they do not implement themselves by forwarding them, so `class_getMethodImplementation` gives the
/// forwarding entry, which the cast's signature then feeds.
enum ObjC {
    static func implementation<T>(_ object: AnyObject, _ selector: String, as type: T.Type) -> (T, Selector) {
        let selector = NSSelectorFromString(selector)
        let implementation = class_getMethodImplementation(object_getClass(object), selector)!
        return (unsafeBitCast(implementation, to: type), selector)
    }

    static func object(_ object: AnyObject, _ selector: String) -> AnyObject? {
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let (call, name) = implementation(object, selector, as: Getter.self)
        return call(object, name)?.takeUnretainedValue()
    }

    static func uint32(_ object: AnyObject, _ selector: String) -> UInt32 {
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt32
        let (call, name) = implementation(object, selector, as: Getter.self)
        return call(object, name)
    }

    static func int32(_ object: AnyObject, _ selector: String) -> Int32 {
        typealias Getter = @convention(c) (AnyObject, Selector) -> Int32
        let (call, name) = implementation(object, selector, as: Getter.self)
        return call(object, name)
    }

    static func uint64(_ object: AnyObject, _ selector: String) -> UInt64 {
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt64
        let (call, name) = implementation(object, selector, as: Getter.self)
        return call(object, name)
    }

    static func float(_ object: AnyObject, _ selector: String) -> Float {
        typealias Getter = @convention(c) (AnyObject, Selector) -> Float
        let (call, name) = implementation(object, selector, as: Getter.self)
        return call(object, name)
    }

    static func size(_ object: AnyObject, _ selector: String) -> CGSize {
        typealias Getter = @convention(c) (AnyObject, Selector) -> CGSize
        let (call, name) = implementation(object, selector, as: Getter.self)
        return call(object, name)
    }

    static func conforms(_ object: AnyObject, to protocolName: String) -> Bool {
        guard let declared = objc_getProtocol(protocolName) else { return false }
        return (object as? NSObjectProtocol)?.conforms(to: declared) ?? class_conformsToProtocol(object_getClass(object), declared)
    }
}
