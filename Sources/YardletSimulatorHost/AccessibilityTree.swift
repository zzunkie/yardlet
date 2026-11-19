import CoreGraphics
import Darwin
import Foundation
import ObjectiveC
import YardletSimulatorHostProtocol

/// The app in front's accessibility elements, read as Xcode's Accessibility Inspector and Meta's idb read them: macOS's
/// AccessibilityPlatformTranslation framework (`AXPTranslator`) asks the device's own accessibility runtime for the app
/// and each element's attributes through CoreSimulator (`-[SimDevice sendAccessibilityRequestAsync:completionQueue:
/// completionHandler:]`), and hands back macOS accessibility elements that live in the helper's process. Nothing goes
/// through macOS's accessibility API to another process, so no Accessibility permission is involved; the helper's
/// sandbox, which reaches no TCC service, is the same as for frames and input.
///
/// Requests run one at a time on the main queue, which the helper leaves free otherwise; the device's answers come on
/// a queue of their own while a request waits for them.
final class AccessibilityTree: @unchecked Sendable {
    static let frameworkPath =
        "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation"
    /// A screen of an ordinary app has tens of elements, a long list a few hundred; each costs a few round trips.
    static let maximumElements = 600
    static let maximumDepth = 64
    static let timeLimit = 15.0
    /// How long one request to the device may take.
    static let requestTimeout = 5.0

    static let translatorMethods = ["setBridgeTokenDelegate:", "frontmostApplicationWithDisplayId:bridgeDelegateToken:",
                                    "macPlatformElementFromTranslation:"]
    static let elementMethods = ["accessibilityAttributeValue:", "accessibilityFrame", "accessibilityLabel", "translation"]

    private let translator: AnyObject
    private let bridge: Bridge

    private init(translator: AnyObject, bridge: Bridge) {
        self.translator = translator
        self.bridge = bridge
    }

    /// The framework and every class and method the tree uses, or nil (the helper then offers no tree).
    static func load() -> AccessibilityTree? {
        guard dlopen(frameworkPath, RTLD_NOW) != nil,
              let translatorClass: AnyClass = NSClassFromString("AXPTranslator"),
              let elementClass: AnyClass = NSClassFromString("AXPMacPlatformElement"),
              let translationClass: AnyClass = NSClassFromString("AXPTranslationObject"),
              let deviceClass: AnyClass = NSClassFromString("SimDevice"),
              let delegateProtocol = objc_getProtocol("AXPTranslationTokenDelegateHelper"),
              class_getClassMethod(translatorClass, NSSelectorFromString("sharedInstance")) != nil,
              translatorMethods.allSatisfy({ class_getInstanceMethod(translatorClass, NSSelectorFromString($0)) != nil }),
              elementMethods.allSatisfy({ class_getInstanceMethod(elementClass, NSSelectorFromString($0)) != nil }),
              class_getInstanceMethod(translationClass, NSSelectorFromString("setBridgeDelegateToken:")) != nil,
              class_getInstanceMethod(deviceClass, NSSelectorFromString(Bridge.sendSelector)) != nil
        else { return nil }
        class_addProtocol(Bridge.self, delegateProtocol)
        typealias Shared = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        let (shared, selector) = ObjC.implementation(translatorClass, "sharedInstance", as: Shared.self)
        guard let translator = shared(translatorClass, selector)?.takeUnretainedValue() else { return nil }
        let bridge = Bridge()
        _ = translator.perform(NSSelectorFromString("setBridgeTokenDelegate:"), with: bridge)
        return AccessibilityTree(translator: translator, bridge: bridge)
    }

    /// The elements of the app in front on `device` (a `SimDevice`), with its application element at the top.
    func elements(of device: AnyObject) throws -> (elements: [SimulatorAccessibilityElement], truncated: Bool) {
        let token = UUID().uuidString
        bridge.add(device, for: token)
        defer { bridge.remove(token) }
        typealias Frontmost = @convention(c) (AnyObject, Selector, UInt32, NSString) -> Unmanaged<AnyObject>?
        let (frontmost, selector) = ObjC.implementation(translator, "frontmostApplicationWithDisplayId:bridgeDelegateToken:",
                                                        as: Frontmost.self)
        guard let translation = frontmost(translator, selector, 0, token as NSString)?.takeUnretainedValue() else {
            throw HostError("the device's accessibility runtime named no app in front")
        }
        _ = translation.perform(NSSelectorFromString("setBridgeDelegateToken:"), with: token as NSString)
        guard let root = translator.perform(NSSelectorFromString("macPlatformElementFromTranslation:"), with: translation)?
            .takeUnretainedValue() else {
            throw HostError("the app in front gave no accessibility element")
        }
        var walk = Walk(token: token, deadline: Date().addingTimeInterval(Self.timeLimit))
        let top = walk.read(root, depth: 0)
        return ([top], walk.truncated)
    }

    private struct Walk {
        let token: String
        let deadline: Date
        var count = 0
        var truncated = false

        mutating func read(_ element: AnyObject, depth: Int) -> SimulatorAccessibilityElement {
            count += 1
            // The elements a translation hands back ask the device through the token they carry.
            if let translation = ObjC.object(element, "translation") {
                _ = translation.perform(NSSelectorFromString("setBridgeDelegateToken:"), with: token as NSString)
            }
            let frame = AccessibilityTree.frame(of: element)
            var read = SimulatorAccessibilityElement(
                role: AccessibilityTree.attribute(element, "AXRole") as? String ?? "AXUnknown",
                label: AccessibilityTree.text(element.perform(NSSelectorFromString("accessibilityLabel"))?.takeUnretainedValue()),
                value: AccessibilityTree.text(AccessibilityTree.attribute(element, "AXValue")),
                identifier: AccessibilityTree.text(AccessibilityTree.attribute(element, "AXIdentifier")),
                x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height)
            guard depth < AccessibilityTree.maximumDepth else {
                truncated = true
                return read
            }
            for child in AccessibilityTree.attribute(element, "AXChildren") as? [AnyObject] ?? [] {
                guard count < AccessibilityTree.maximumElements, Date() < deadline else {
                    truncated = true
                    break
                }
                read.children.append(self.read(child, depth: depth + 1))
            }
            return read
        }
    }

    private static func attribute(_ element: AnyObject, _ name: String) -> Any? {
        element.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: name as NSString)?.takeUnretainedValue()
    }

    private static func frame(of element: AnyObject) -> CGRect {
        typealias Frame = @convention(c) (AnyObject, Selector) -> CGRect
        let (frame, selector) = ObjC.implementation(element, "accessibilityFrame", as: Frame.self)
        let rect = frame(element, selector)
        return rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite ? rect : .zero
    }

    /// A string, or a number or truth value as its text; nil when empty.
    private static func text(_ value: Any?) -> String? {
        let text: String? = switch value {
        case let string as String: string
        case let attributed as NSAttributedString: attributed.string
        case let number as NSNumber: number.stringValue
        default: nil
        }
        return text.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// The translator's way to the devices: each request carries the token of the tree being read, which names the device
/// it goes to.
private final class Bridge: NSObject {
    static let sendSelector = "sendAccessibilityRequestAsync:completionQueue:completionHandler:"

    private let lock = NSLock()
    private var devices: [String: AnyObject] = [:]
    private let answers = DispatchQueue(label: "Yardlet simulator host accessibility answers")

    func add(_ device: AnyObject, for token: String) {
        lock.withLock { devices[token] = device }
    }

    func remove(_ token: String) {
        _ = lock.withLock { devices.removeValue(forKey: token) }
    }

    @objc func accessibilityTranslationDelegateBridgeCallbackWithToken(_ token: NSString) -> Any {
        let device = lock.withLock { devices[token as String] }
        let answers = self.answers
        let send: @convention(block) (AnyObject) -> AnyObject? = { request in
            guard let device else { return nil }
            typealias Send = @convention(c) (AnyObject, Selector, AnyObject, DispatchQueue,
                                             @escaping @convention(block) (AnyObject?) -> Void) -> Void
            let (call, selector) = ObjC.implementation(device, Bridge.sendSelector, as: Send.self)
            let answered = DispatchSemaphore(value: 0)
            let box = Box()
            call(device, selector, request, answers) { response in
                box.value = response
                answered.signal()
            }
            guard answered.wait(timeout: .now() + AccessibilityTree.requestTimeout) == .success else { return nil }
            return box.value
        }
        return send
    }

    /// Frames come in the device's points, which is what the tree gives.
    @objc func accessibilityTranslationConvertPlatformFrameToSystem(_ rect: CGRect, withToken token: NSString) -> CGRect {
        rect
    }

    @objc func accessibilityTranslationRootParentWithToken(_ token: NSString) -> AnyObject? {
        nil
    }

    private final class Box: @unchecked Sendable {
        var value: AnyObject?
    }
}
