import XCTest
@testable import VMCore
final class HostProxyTests: XCTestCase {
  func testNATMapsOnlyLoopbackAndKeepsProtocolsAndBypasses() throws {
    let proxy = try XCTUnwrap(HostProxy.from(settings: ["HTTPEnable":1,"HTTPProxy":"127.0.0.1","HTTPPort":7898,"HTTPSEnable":1,"HTTPSProxy":"proxy.example","HTTPSPort":8080,"ExceptionsList":["*.haier.net,*.local"]]))
    XCTAssertEqual(proxy.server,"http=10.0.2.2:7898;https=proxy.example:8080")
    XCTAssertEqual(proxy.testProxy,"http://proxy.example:8080")
    XCTAssertTrue(proxy.bypass.contains("10.*"))
    XCTAssertTrue(proxy.bypass.contains("*.haier.net;*.local"))
    XCTAssertNil(HostProxy.from(settings:["HTTPEnable":0,"HTTPProxy":"127.0.0.1","HTTPPort":7898]))
    XCTAssertNil(HostProxy.from(settings:["HTTPEnable":1,"HTTPProxy":"bad;host","HTTPPort":7898]))
  }
}
