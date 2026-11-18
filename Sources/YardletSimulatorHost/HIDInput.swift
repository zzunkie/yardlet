import CoreGraphics
import Darwin
import Foundation
import ObjectiveC
import YardletSimulatorHostProtocol

/// A device's touches, buttons and keys, sent through SimulatorKit's HID client for the device. Each Indigo message
/// is allocated by SimulatorKit and freed by it once sent (`freeWhenDone`).
final class HIDInput {
    /// The digitizer service: touches, and the HID usages of the device's buttons.
    static let digitizerTarget: UInt32 = 0x32
    /// The legacy button service: home and lock.
    static let buttonTarget: UInt32 = 0x33
    private static let buttonDown: UInt32 = 1
    private static let buttonUp: UInt32 = 2
    /// A press holds a button or key this long; a shorter one can go unnoticed.
    private static let pressDuration: TimeInterval = 0.05
    /// Between typed keys, so the device's text system sees each one.
    private static let keyGap: TimeInterval = 0.01

    private let kit: SimulatorKit
    private let client: AnyObject

    init(kit: SimulatorKit, device: AnyObject) throws {
        self.kit = kit
        typealias Allocate = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        typealias Initialize = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<Unmanaged<NSError>?>?)
            -> Unmanaged<AnyObject>?
        let allocSelector = NSSelectorFromString("alloc")
        let allocate = unsafeBitCast(class_getMethodImplementation(object_getClass(kit.hidClientClass), allocSelector)!,
                                     to: Allocate.self)
        // `alloc` returns an object the initializer consumes, as `init` methods do: it is passed on unretained.
        guard let allocated = allocate(kit.hidClientClass, allocSelector)?.takeUnretainedValue() else {
            throw HostError("SimulatorKit made no HID client")
        }
        let (initialize, initSelector) = ObjC.implementation(allocated, "initWithDevice:error:", as: Initialize.self)
        var error: Unmanaged<NSError>?
        guard let client = initialize(allocated, initSelector, device, &error)?.takeRetainedValue() else {
            throw HostError("the device's HID client did not start: \(error?.takeUnretainedValue().localizedDescription ?? "no reason given")")
        }
        self.client = client
    }

    func touch(_ phase: SimulatorTouchPhase, at point: SimulatorPoint) throws {
        if let message = digitizerMessage(phase, at: point) {
            try send(message)
            return
        }
        var position = CGPoint(x: point.x, y: point.y)
        // NSEventType: left mouse down, up and dragged.
        let eventType: UInt = switch phase {
        case .down: 1
        case .up: 2
        case .move: 6
        }
        try send(kit.mouseMessage(&position, nil, Self.digitizerTarget, eventType, CGSize(width: 1, height: 1), 0))
    }

    func button(_ button: SimulatorButton, _ phase: SimulatorPressPhase) throws {
        try press(phase) { [kit] direction in
            switch button {
            case .home: kit.buttonMessage(0, direction, Self.buttonTarget)
            case .lock: kit.buttonMessage(1, direction, Self.buttonTarget)
            // The usages the device chrome gives each button (DeviceKit's chrome.json, `inputs`).
            case .volumeUp: kit.arbitraryMessage(Self.digitizerTarget, 0x0C, 0xE9, direction)
            case .volumeDown: kit.arbitraryMessage(Self.digitizerTarget, 0x0C, 0xEA, direction)
            case .power: kit.arbitraryMessage(Self.digitizerTarget, 0x0C, 0x30, direction)
            case .action: kit.arbitraryMessage(Self.digitizerTarget, 0x0B, 0x2D, direction)
            }
        }
    }

    /// Keys go to the keyboard service, as a hardware keyboard's do, so the device's own keyboard layout reads them.
    func key(_ usage: SimulatorKeyUsage, _ phase: SimulatorPressPhase) throws {
        try press(phase) { [kit] direction in kit.keyboardMessage(usage.rawValue, direction) }
    }

    func type(_ text: SimulatorKeyboardText) throws {
        for scalar in text.text.unicodeScalars {
            guard let stroke = SimulatorKeyboard.stroke(for: scalar) else { continue }
            if stroke.shift { try key(SimulatorKeyboard.leftShift, .down) }
            try send(kit.keyboardMessage(stroke.usage.rawValue, Self.buttonDown))
            try send(kit.keyboardMessage(stroke.usage.rawValue, Self.buttonUp))
            if stroke.shift { try key(SimulatorKeyboard.leftShift, .up) }
            Thread.sleep(forTimeInterval: Self.keyGap)
        }
    }

    private func press(_ phase: SimulatorPressPhase, _ message: (UInt32) -> UnsafeMutableRawPointer?) throws {
        if phase != .up { try send(message(Self.buttonDown)) }
        if phase == .press { Thread.sleep(forTimeInterval: Self.pressDuration) }
        if phase != .down { try send(message(Self.buttonUp)) }
    }

    /// One finger as IOKit digitizer events: a hand with the finger as its child, which reaches system layers too.
    private func digitizerMessage(_ phase: SimulatorTouchPhase, at point: SimulatorPoint) -> UnsafeMutableRawPointer? {
        guard let functions = kit.digitizer else { return nil }
        let time = mach_absolute_time()
        let lifted = phase == .up
        // Range, touch and position; a lifted finger is out of range and no longer touching.
        let mask: UInt32 = lifted ? 0x06 : 0x07
        let contact: UInt8 = lifted ? 0 : 1
        guard let hand = functions.createDigitizerEvent(nil, time, 2, 0, 1, mask, 0, point.x, point.y, 0, 0, 0,
                                                        contact, contact, 0) else { return nil }
        defer { Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(hand)).release() }
        guard let finger = functions.createFingerEvent(nil, time, 1, 1, mask, point.x, point.y, 0, 0, 0,
                                                       contact, contact, 0) else { return nil }
        functions.appendEvent(hand, finger, 0)
        Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(finger)).release()
        guard let message = functions.message(hand, Self.digitizerTarget) else { return nil }
        // The digitizer service reads its target at 0x6c of the message (and of its second part at 0x10c). Xcode 27
        // writes the target given above there; Xcode 26's function took no target and wrote the trackpad's, which the
        // device ignores for touches.
        let size = malloc_size(message)
        for offset in [0x6c, 0x10c] where size >= offset + 4 {
            if message.load(fromByteOffset: offset, as: UInt32.self) != Self.digitizerTarget {
                message.storeBytes(of: Self.digitizerTarget, toByteOffset: offset, as: UInt32.self)
            }
        }
        return message
    }

    private func send(_ message: UnsafeMutableRawPointer?) throws {
        guard let message else { throw HostError("SimulatorKit made no message for this input") }
        typealias Send = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, ObjCBool, AnyObject?, AnyObject?) -> Void
        let (send, selector) = ObjC.implementation(client, "sendWithMessage:freeWhenDone:completionQueue:completion:", as: Send.self)
        send(client, selector, message, true, nil, nil)
    }
}

struct HostError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
