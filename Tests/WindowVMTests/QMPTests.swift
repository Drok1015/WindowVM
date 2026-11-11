import XCTest
import Darwin
@testable import WindowVM

final class QMPTests: XCTestCase {
  /// Fake monitor sends unsolicited events too, and rejects a migration without
  /// killing the guest. No production VM or sockets are used.
  func testFailedSaveResumesGuestAndNeverQuits() throws {
    let path = "/tmp/wvm-\(UUID().uuidString).sock"
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(listener, 0)
    defer { close(listener); unlink(path) }
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    XCTAssertEqual(bound, 0); XCTAssertEqual(listen(listener, 1), 0)
    let finished = expectation(description: "monitor received rollback without quit")
    DispatchQueue.global().async {
      let client = accept(listener, nil, nil)
      guard client >= 0 else { XCTFail("accept"); finished.fulfill(); return }
      defer { close(client); finished.fulfill() }
      var timeout = timeval(tv_sec: 3, tv_usec: 0)
      setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
      func send(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object) + Data([10])
        _ = data.withUnsafeBytes { write(client, $0.baseAddress!, $0.count) }
      }
      send(["QMP": [:]])
      let expected = ["qmp_capabilities", "query-migrate", "stop", "migrate", "query-migrate", "migrate_cancel", "query-migrate", "cont", "query-status"]
      for command in expected {
        var data = Data(); var byte: UInt8 = 0
        while read(client, &byte, 1) == 1 { data.append(byte); if byte == 10 { break } }
        guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { XCTFail("missing \(command)"); return }
        XCTAssertEqual(request["execute"] as? String, command)
        send(["event": "TEST_EVENT"])
        var result: [String: Any] = [:]
        // The first query is a preflight; all queries following stop fail.
        if command == "query-migrate", data.count > 0, (request["id"] as? Int ?? 0) > 2 {
          result = ["status": "failed", "error-desc": "injected disk full"]
        }
        if command == "query-status" { result = ["running": true, "status": "running"] }
        send(["return": result, "id": request["id"]!])
      }
    }
    let file = URL(fileURLWithPath: "/tmp/wvm-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: file) }
    let control = try QMPConnection(path: path)
    var committed = false
    XCTAssertThrowsError(try control.saveState(to: file) { committed = true })
    XCTAssertFalse(committed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    wait(for: [finished], timeout: 5)
  }
}
