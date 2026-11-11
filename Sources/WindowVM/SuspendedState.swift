import Foundation
import CryptoKit
import VMCore

/// A single-use checkpoint paired with the unchanged disk, firmware, TPM and media.
struct SuspendedState: Codable {
  struct FileStamp: Codable, Equatable {
    var path: String
    var size: UInt64
    var modified: Date
    init(_ path: String) throws {
      let a = try FileManager.default.attributesOfItem(atPath: path)
      self.path = path
      size = (a[.size] as? NSNumber)?.uint64Value ?? 0
      modified = a[.modificationDate] as? Date ?? .distantPast
    }
  }
  var version = 1
  var savedAt = Date()
  var arguments: [String]
  var configuration: VMConfiguration
  var engineHash: String
  var tpmHash: String
  var firmwareHash: String
  var files: [FileStamp] = []

  static func digest(_ path: String) throws -> String {
    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? file.close() }
    var hash = SHA256()
    while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  static func write<T: Encodable>(_ value: T, to url: URL) throws {
    // Temp and destination files live under the owner's 0700 VM directory.
    try JSONEncoder().encode(value).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let file = try FileHandle(forWritingTo: url); defer { try? file.close() }; try file.synchronize()
  }
  mutating func seal(directory: URL, stateFile: URL) throws {
    var paths = ["windows.qcow2", "efi-vars.fd", "guest-tools.iso"].map { directory.appendingPathComponent($0).path }
    // All external ISO media must remain unchanged until the checkpoint is consumed.
    for argument in arguments where argument.hasPrefix("if=none,") {
      if let range = argument.range(of: "file="), argument.contains("media=cdrom") {
        paths.append(String(argument[range.upperBound...]))
      }
    }
    if let enumerator = FileManager.default.enumerator(at: directory.appendingPathComponent("tpm"), includingPropertiesForKeys: [.isRegularFileKey]) {
      for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { paths.append(url.path) }
    }
    paths.append(stateFile.path)
    files = try Set(paths).sorted().map(FileStamp.init)
  }
  func validate(arguments: [String], configuration: VMConfiguration, engine: String, firmware: String) throws {
    guard version == 1, self.arguments == arguments, self.configuration == configuration,
          engineHash == (try Self.digest(engine)), tpmHash == (try Self.digest("/opt/homebrew/bin/swtpm")),
          firmwareHash == (try Self.digest(firmware)), !files.isEmpty else {
      throw VMError.message("暂停状态与当前引擎、固件或配置不匹配。已保留保存文件，未启动 Windows；请恢复保存时的版本与配置。")
    }
    for stamp in files where try FileStamp(stamp.path) != stamp {
      throw VMError.message("暂停期间文件发生变化：\(URL(fileURLWithPath: stamp.path).lastPathComponent)。为避免状态错配，已保留保存文件并停止恢复。")
    }
  }
}
