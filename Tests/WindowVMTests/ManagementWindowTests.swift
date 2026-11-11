import XCTest
import AppKit
@testable import WindowVM

final class ManagementWindowTests: XCTestCase {
  final class OriginalDelegate: NSObject, NSWindowDelegate {
    var zoomWasForwarded = false
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
      zoomWasForwarded = true
      return false
    }
  }

  @MainActor func testCloseHidesManagerAndPreservesSwiftUIWindowCallbacks() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let original = OriginalDelegate()
    let proxy = ManagementWindowDelegate()
    proxy.original = original
    window.delegate = proxy
    window.orderFront(nil)
    XCTAssertTrue(window.isVisible)
    window.performClose(nil)
    XCTAssertFalse(window.isVisible)
    // The same live window can be shown again; Close did not destroy it.
    window.makeKeyAndOrderFront(nil)
    XCTAssertTrue(window.isVisible)
    let delegate: NSWindowDelegate = proxy
    XCTAssertFalse(delegate.windowShouldZoom?(window, toFrame: .zero) ?? true)
    XCTAssertTrue(original.zoomWasForwarded)
    window.orderOut(nil)
    window.delegate = nil
    window.close()
  }
}
