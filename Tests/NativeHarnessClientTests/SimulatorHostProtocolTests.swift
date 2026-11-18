import Foundation
import XCTest
import YardletSimulatorHostProtocol

/// The simulator host takes only well-formed commands: what Yardlet checked, it checks again as it decodes them.
final class SimulatorHostProtocolTests: XCTestCase {
    private func decodes(_ json: String) -> Bool {
        (try? JSONDecoder().decode(SimulatorHostCommand.self, from: Data(json.utf8))) != nil
    }

    func testTheHelperRefusesCommandsOutsideTheirBounds() throws {
        let device = "8A0F2C1E-37B2-4C6A-9E61-0D3F5B2A7C11"
        XCTAssertTrue(decodes(#"{"touch":{"device":"\#(device)","phase":"down","point":{"x":0,"y":1}}}"#))
        // A point is a fraction of the screen.
        XCTAssertFalse(decodes(#"{"touch":{"device":"\#(device)","phase":"down","point":{"x":1.01,"y":0.5}}}"#))
        XCTAssertFalse(decodes(#"{"touch":{"device":"\#(device)","phase":"down","point":{"x":-0.1,"y":0.5}}}"#))
        // A device is a UUID.
        XCTAssertFalse(decodes(#"{"attach":{"device":"../../etc"}}"#))
        // A key is a keyboard usage.
        XCTAssertTrue(decodes(#"{"key":{"device":"\#(device)","usage":40,"phase":"press"}}"#))
        XCTAssertFalse(decodes(#"{"key":{"device":"\#(device)","usage":65536,"phase":"press"}}"#))
        // Keyboard text is printable ASCII, newlines and tabs, within its length.
        XCTAssertTrue(decodes(#"{"typeText":{"device":"\#(device)","text":"Hello, World!\n"}}"#))
        XCTAssertFalse(decodes(#"{"typeText":{"device":"\#(device)","text":"안녕"}}"#))
        let long = String(repeating: "a", count: SimulatorKeyboardText.maximumLength + 1)
        XCTAssertFalse(decodes(#"{"typeText":{"device":"\#(device)","text":"\#(long)"}}"#))
        // No command names a selector, a class or a path.
        XCTAssertFalse(decodes(#"{"perform":{"selector":"terminate:"}}"#))
    }
}
