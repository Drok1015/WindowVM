import XCTest
@testable import VMCore
final class VMCoreTests: XCTestCase {
  func testSafeNetworkAndNativeArchitecture() throws {
    let plan = try LaunchPlan(configuration: VMConfiguration(), directory: URL(fileURLWithPath: "/tmp/Windows VM"), firmware: "/tmp/code.fd")
    XCTAssertTrue(plan.arguments.contains("hvf"))
    XCTAssertTrue(plan.arguments.contains("user,id=net0,hostfwd=tcp:127.0.0.1:18080-:8080"))
    XCTAssertTrue(plan.arguments.contains("nvme,drive=system,serial=WINDOWVM001,bootindex=1"))
    XCTAssertFalse(plan.arguments.contains(where: { $0.contains("id=installer") }))
  }
  func testInvalidPortAndCommaPathsAreRejected() {
    var c = VMConfiguration()
    c.forwardGuestPort = 0
    XCTAssertThrowsError(try c.validate())
    XCTAssertThrowsError(try LaunchPlan(configuration: VMConfiguration(), directory: URL(fileURLWithPath: "/tmp/a,b"), firmware: "/tmp/code.fd"))
  }
  func testClipboardRejectsStaleUpdatesAndPreservesUnicode() {
    var s = ClipboardState()
    s.observe("中文 👋")
    XCTAssertFalse(s.accept(ClipboardUpdate(baseVersion: 0, text: "old")))
    XCTAssertEqual(s.snapshot.text, "中文 👋")
    XCTAssertTrue(s.accept(ClipboardUpdate(baseVersion: 1, text: "Windows\r\n文本")))
    XCTAssertEqual(s.snapshot.version, 2)
    s.observe("Windows\r\n文本")
    XCTAssertEqual(s.snapshot.version, 2)
  }
}
