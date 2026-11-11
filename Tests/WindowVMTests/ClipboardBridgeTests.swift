import XCTest
import AppKit
@testable import WindowVM
import VMCore

final class ClipboardBridgeTests: XCTestCase {
  @MainActor func testHTTPAuthenticationUnicodeAndConflicts() async throws {
    let pasteboard = NSPasteboard(name: .init("WindowVM.Tests.\(UUID())"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("宿主 👋", forType: .string)
    let bridge = ClipboardBridge(pasteboard: pasteboard)
    let port = try await bridge.start(token: "test-only-token", port: 0)
    defer { bridge.stop() }
    let url = URL(string: "http://127.0.0.1:\(port)/clipboard")!
    func send(method: String = "GET", token: String = "test-only-token", body: Data? = nil) async throws -> (Data, Int) {
      var request = URLRequest(url: url)
      request.httpMethod = method
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.httpBody = body
      let (data, response) = try await URLSession.shared.data(for: request)
      return (data, (response as! HTTPURLResponse).statusCode)
    }
    let denied = try await send(token: "wrong")
    XCTAssertEqual(denied.1, 401)
    let initial = try await send()
    XCTAssertEqual(initial.1, 200)
    let first = try JSONDecoder().decode(ClipboardSnapshot.self, from: initial.0)
    XCTAssertEqual(first.text, "宿主 👋")
    let payload = Data("{\"baseVersion\":\(first.version),\"text\":\"Windows 中文\\r\\n第二行\"}".utf8)
    let accepted = try await send(method: "PUT", body: payload)
    XCTAssertEqual(accepted.1, 200)
    XCTAssertEqual(pasteboard.string(forType: .string), "Windows 中文\r\n第二行")
    let stale = try await send(method: "PUT", body: payload)
    XCTAssertEqual(stale.1, 409)
    let invalid = try await send(method: "PUT", body: Data("{}".utf8))
    XCTAssertEqual(invalid.1, 400)
  }
}

extension ClipboardBridgeTests {
  @MainActor func testDisplayRequestsStayAuthenticatedAndRejectStaleAcknowledgements() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let board = NSPasteboard(name: .init("WindowVM.DisplayTests.\(UUID())"))
    defer { board.releaseGlobally() }
    let bridge = ClipboardBridge(pasteboard: board)
    let port = try await bridge.start(token: "display-token", port: 0, directory: directory, clipboardEnabled: false)
    defer { bridge.stop() }
    func send(_ path: String, method: String = "GET", token: String = "display-token", body: String? = nil) async throws -> (Data, Int) {
      var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
      r.httpMethod = method; r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      r.httpBody = body.map { Data($0.utf8) }
      let (data, response) = try await URLSession.shared.data(for: r)
      return (data, (response as! HTTPURLResponse).statusCode)
    }
    let denied = try await send("/display", token: "wrong")
    XCTAssertEqual(denied.1, 401)
    let clipboard = try await send("/clipboard")
    XCTAssertEqual(clipboard.1, 403)
    try Data("{\"id\":\"current\",\"width\":1280,\"height\":800,\"intervalMs\":800}".utf8)
      .write(to: directory.appendingPathComponent("display-request.json"))
    let request = try await send("/display")
    XCTAssertEqual(try JSONDecoder().decode(DisplayRequest.self, from: request.0).width, 1280)
    let stale = try await send("/display", method: "POST", body: "{\"id\":\"old\",\"width\":1280,\"height\":800,\"success\":true}")
    XCTAssertEqual(stale.1, 409)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("display-configured").path))
    let accepted = try await send("/display", method: "POST", body: "{\"id\":\"current\",\"width\":1280,\"height\":800,\"success\":true}")
    XCTAssertEqual(accepted.1, 200)
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("display-configured").path))
    try Data("{\"id\":\"invalid\",\"width\":99999,\"height\":1,\"intervalMs\":800}".utf8)
      .write(to: directory.appendingPathComponent("display-request.json"))
    let invalid = try await send("/display")
    XCTAssertEqual(String(decoding: invalid.0, as: UTF8.self), "null")
  }
}
