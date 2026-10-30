import Foundation
import XCTest

/// How a browser QA run is judged (`scripts/browser-host-qa/verdict.sh`, which `run-check.sh` ends with): only a
/// fixture that reached its end with every recorded check ok passes. Before, a run that printed FAIL still ended
/// with status 0.
final class BrowserCheckVerdictTests: XCTestCase {
    private let script = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "scripts/browser-host-qa/verdict.sh")

    func testOnlyAFinishedRunWithEveryCheckOkPasses() throws {
        let ok = #"{"check": "tabs", "ok": true, "detail": ""}"#
        let failed = #"{"check": "vault", "ok": false, "detail": "filled nothing"}"#
        XCTAssertEqual(try verdict(result: #"{"checks": [\#(ok), \#(ok)]}"#, finished: true).status, 0)

        let one = try verdict(result: #"{"checks": [\#(ok), \#(failed)]}"#, finished: true)
        XCTAssertEqual(one.status, 1)
        XCTAssertTrue(one.output.contains("FAIL vault: filled nothing"), one.output)
        XCTAssertEqual(try verdict(result: #"{"checks": [\#(ok)]}"#, finished: false).status, 1,
                       "A run that stopped early skipped the checks after its last")
        XCTAssertEqual(try verdict(result: #"{"checks": []}"#, finished: true).status, 1, "Nothing was checked")
        XCTAssertEqual(try verdict(result: #"{"checks": [{"check": "tabs", "detail": ""}]}"#, finished: true).status, 1,
                       "A check without an answer is not ok")
        XCTAssertEqual(try verdict(result: #"{"checks": [\#(ok)"#, finished: true).status, 1, "A cut-off file")
        XCTAssertEqual(try verdict(result: nil, finished: true).status, 1, "No result at all")
    }

    private func verdict(result: String?, finished: Bool) throws -> (status: Int32, output: String) {
        let out = FileManager.default.temporaryDirectory.appending(path: "yardlet-verdict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out.appending(path: "markers"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: out) }
        if let result { try Data(result.utf8).write(to: out.appending(path: "result.json")) }
        if finished { try Data("done".utf8).write(to: out.appending(path: "markers/finished")) }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = [script.path(percentEncoded: false), out.path(percentEncoded: false)]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
