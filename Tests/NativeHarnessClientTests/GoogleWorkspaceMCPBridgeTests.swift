import Foundation
import XCTest
@testable import NativeHarnessClient
import YardletAgentTools

final class GoogleWorkspaceMCPBridgeTests: XCTestCase {
    typealias Bridge = GoogleWorkspaceMCPBridge

    private func arguments(_ attachments: [[String: ToolJSON]]) -> ToolJSON {
        .object(["account": .string("account@example.test"), "attachments": .array(attachments.map(ToolJSON.object))])
    }

    func testAttachmentSchemaAcceptsPathOrOriginalRequiredFields() throws {
        let tool = try JSONDecoder().decode(ToolJSON.self, from: Data("""
        {"name":"reply","inputSchema":{"type":"object","properties":{"attachments":{"type":"array","items":{
        "type":"object","properties":{"filename":{"type":"string"},"content":{"type":"string"},"inline":{"type":"boolean"}},
        "required":["filename","content","inline"],"additionalProperties":false}}}}}
        """.utf8))
        let item = Bridge.exposedTool(tool)["inputSchema"]?["properties"]?["attachments"]?["items"]
        XCTAssertEqual(item?["properties"]?["path"]?["type"], .string("string"))
        XCTAssertEqual(item?["required"], .array([.string("inline")]))
        XCTAssertEqual(item?["oneOf"]?.arrayValue?.first?["required"], .array([.string("filename"), .string("content")]))
        XCTAssertEqual(item?["oneOf"]?.arrayValue?.last?["required"], .array([.string("path")]))
    }

    func testAllAttachmentToolsPrepareVisibleFilesAndKeepInlineFields() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".png")
        let data = Data([1, 2, 3])
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let input = arguments([["path": .string(url.nativePath), "inline": .bool(true)]])
        for name in ["create_draft", "update_draft", "send_message", "reply", "forward"] {
            let outbound = try Bridge.prepareArguments(name: name, arguments: input, taskFolders: [])
            XCTAssertNil(outbound["account"])
            let attachment = outbound["attachments"]?.arrayValue?.first
            XCTAssertNil(attachment?["path"])
            XCTAssertEqual(attachment?["content"], .string(data.base64EncodedString()))
            XCTAssertEqual(attachment?["filename"], .string(url.lastPathComponent))
            XCTAssertEqual(attachment?["mimeType"], .string("image/png"))
            XCTAssertEqual(attachment?["inline"], .bool(true))
        }
    }

    func testHiddenFilesAndLinkOutsideRootsAreRefused() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hidden = root.appending(path: ".env")
        try Data().write(to: hidden)
        let link = root.appending(path: "elsewhere")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(filePath: "/bin/sh"))
        for path in ["~/.ssh/id_rsa", hidden.nativePath, link.nativePath] {
            XCTAssertThrowsError(try Bridge.prepareArguments(name: "reply", arguments: arguments([["path": .string(path)]]),
                                                            taskFolders: [root]))
        }
    }

    func testRawBudgetIncludesEncodedAndLocalAttachmentsTogether() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(Bridge.rawLimit))
        try handle.close()
        let inputs: [[String: ToolJSON]] = [["content": .string("AA==")], ["path": .string(file.nativePath)]]
        XCTAssertThrowsError(try Bridge.prepareArguments(name: "create_draft", arguments: arguments(inputs), taskFolders: [])) {
            XCTAssertTrue($0.localizedDescription.contains("18 MB"))
        }
    }

    func testGoogleFileLinksAreNormalizedInOnlyTheIDFields() throws {
        for (key, url) in [
            ("fileId", "https://drive.google.com/file/d/my-ID/view"),
            ("fileId", "https://drive.google.com/open?id=my-ID"),
            ("fileId", "https://drive.google.com/drive/u/0/folders/my-ID"),
            ("documentId", "https://docs.google.com/document/d/my-ID/edit"),
            ("spreadsheetId", "https://docs.google.com/spreadsheets/d/my-ID/edit#gid=0"),
            ("presentationId", "https://docs.google.com/presentation/d/my-ID/edit?slide=3")
        ] {
            let output = try Bridge.prepareArguments(name: "get", arguments: .object([key: .string(url), "text": .string(url)]),
                                                     taskFolders: [])
            XCTAssertEqual(output[key], .string("my-ID"))
            XCTAssertEqual(output["text"], .string(url))
        }
        for id in ["existing_id", "https://example.test/document/d/my-ID/edit"] {
            let args: ToolJSON = .object(["documentId": .string(id)])
            XCTAssertEqual(try Bridge.prepareArguments(name: "get", arguments: args, taskFolders: []), args)
        }
    }

    func testThumbnailDownloadAppendsPNGAndPreservesOriginalOnFailure() async throws {
        for path in ["png", "invalid", "large", "unavailable", "error-result"] {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ThumbnailProtocol.self]
            let text: ToolJSON = .object(["type": .string("text"), "text": .string(
                "{\"contentUrl\":\"https://images.googleusercontent.com/\(path)\"}")])
            let original: ToolJSON = .object(["isError": .bool(path == "error-result"), "content": .array([text])])
            let result = try await Bridge.augmentResult(name: "read_slide_page_thumbnail", result: original, configuration: config)
            if path == "png" {
                XCTAssertEqual(result["content"]?.arrayValue, [text, .object([
                    "type": .string("image"), "mimeType": .string("image/png"), "data": .string(ThumbnailProtocol.png.base64EncodedString())
                ])])
            } else { XCTAssertEqual(result, original) }
        }
    }

    func testThumbnailRedirectDelegateRechecksTheActualDestination() async throws {
        let original = URL(string: "https://images.googleusercontent.com/png")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: original)
        let response = try XCTUnwrap(HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil))
        let (_, completion) = AsyncThrowingStream<Data, Error>.makeStream()
        let delegate = Bridge.ThumbnailDownload(completion: completion)
        for (address, allowed) in [("https://img.ggpht.com/path", true), ("https://img.ggpht.com.example.test/png", false),
                                   ("http://img.googleusercontent.com/png", false), ("https://offsite.test/image", false)] {
            let target = URL(string: address)!
            let next: URLRequest? = await withCheckedContinuation { continuation in
                delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: target)) {
                    continuation.resume(returning: $0)
                }
            }
            XCTAssertEqual(next?.url, allowed ? target : nil)
        }
    }
}

private final class ThumbnailProtocol: URLProtocol, @unchecked Sendable {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAOtmnGkAAAAASUVORK5CYII=")!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNotEqual(url.path, "/error-result")
        let data = url.path == "/invalid" ? Data("text".utf8) : Self.png
        let headers = ["Content-Length": url.path == "/large" ? "20000000" : String(data.count)]
        let response = HTTPURLResponse(url: url, statusCode: url.path == "/unavailable" ? 404 : 200,
                                       httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
