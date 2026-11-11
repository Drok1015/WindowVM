import XCTest
import VMCore
@testable import WindowVM

final class SuspendedStateTests: XCTestCase {
  func testCheckpointRejectsChangedDiskMediaEngineAndConfiguration() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("tpm"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for name in ["windows.qcow2", "efi-vars.fd", "guest-tools.iso", "suspend.bin", "engine", "code.fd", "external.iso", "tpm/state"] {
      try Data("original".utf8).write(to: directory.appendingPathComponent(name))
    }
    let engine = directory.appendingPathComponent("engine").path
    let firmware = directory.appendingPathComponent("code.fd").path
    let arguments = ["-drive", "if=none,id=tools,media=cdrom,readonly=on,file=\(directory.appendingPathComponent("external.iso").path)"]
    let config = VMConfiguration()
    var checkpoint = SuspendedState(arguments: arguments, configuration: config,
      engineHash: try SuspendedState.digest(engine), tpmHash: try SuspendedState.digest("/opt/homebrew/bin/swtpm"),
      firmwareHash: try SuspendedState.digest(firmware))
    try checkpoint.seal(directory: directory, stateFile: directory.appendingPathComponent("suspend.bin"))
    let manifest = directory.appendingPathComponent("suspend.json")
    try SuspendedState.write(checkpoint, to: manifest)
    let decoded = try JSONDecoder().decode(SuspendedState.self, from: Data(contentsOf: manifest))
    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: manifest.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    XCTAssertNoThrow(try decoded.validate(arguments: arguments, configuration: config, engine: engine, firmware: firmware))
    var changed = config; changed.memoryGiB += 1
    XCTAssertThrowsError(try decoded.validate(arguments: arguments, configuration: changed, engine: engine, firmware: firmware))
    XCTAssertThrowsError(try decoded.validate(arguments: arguments + ["changed"], configuration: config, engine: engine, firmware: firmware))
    for name in ["windows.qcow2", "efi-vars.fd", "guest-tools.iso", "suspend.bin", "external.iso", "tpm/state", "engine", "code.fd"] {
      let url = directory.appendingPathComponent(name)
      try checkpoint.seal(directory: directory, stateFile: directory.appendingPathComponent("suspend.bin"))
      try Data("modified and longer".utf8).write(to: url)
      XCTAssertThrowsError(try checkpoint.validate(arguments: arguments, configuration: config, engine: engine, firmware: firmware), name)
      try Data("original".utf8).write(to: url)

    }
    try checkpoint.seal(directory: directory, stateFile: directory.appendingPathComponent("suspend.bin"))
    XCTAssertNoThrow(try checkpoint.validate(arguments: arguments, configuration: config, engine: engine, firmware: firmware))
  }
  func testMigrationChannelHandlesPathsWithoutShellParsing() throws {
    let path = URL(fileURLWithPath: "/tmp/Windows VM's $(state);暂停.bin")
    let data = try JSONSerialization.data(withJSONObject: QMPConnection.fileChannel(path))
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let channel = (object["channels"] as! [[String: Any]])[0]
    let address = channel["addr"] as! [String: Any]
    XCTAssertEqual(address["transport"] as? String, "file")
    XCTAssertEqual(address["filename"] as? String, path.path)
    XCTAssertNil(object["uri"])
  }
}
