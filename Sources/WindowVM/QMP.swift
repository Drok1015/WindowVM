import Foundation
import Darwin
import VMCore

/// A single serial QMP connection. Events may arrive between command replies.
final class QMPConnection {
  private let fd: Int32
  private var sequence = 0
  init(path: String) throws {
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw VMError.message("无法创建控制连接。") }
    do {
      var timeout = timeval(tv_sec: 30, tv_usec: 0)
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
      setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
      var noSignal: Int32 = 1
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      let bytes = Array(path.utf8) + [0]
      guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw VMError.message("控制路径过长。") }
      withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
      let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
      }
      guard connected == 0 else { throw VMError.message("无法连接虚拟机控制接口。") }
      guard try readObject()["QMP"] != nil else { throw VMError.message("虚拟机控制接口握手失败。") }
      _ = try execute("qmp_capabilities")
    } catch { close(fd); throw error }
  }
  deinit { close(fd) }
  private func readObject() throws -> [String: Any] {
    var data = Data()
    while data.count < 2 * 1024 * 1024 {
      var byte: UInt8 = 0
      let count = read(fd, &byte, 1)
      if count < 0 && errno == EINTR { continue }
      guard count == 1 else { throw VMError.message("虚拟机控制接口已断开或响应超时。") }
      data.append(byte)
      if byte == 10 {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
        data.removeAll()
      }
    }
    throw VMError.message("控制接口返回异常。")
  }
  @discardableResult func execute(_ command: String, _ arguments: [String: Any] = [:]) throws -> Any {
    sequence += 1
    let id = sequence
    let payload = try JSONSerialization.data(withJSONObject: ["execute": command, "arguments": arguments, "id": id]) + Data([10])
    try payload.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw VMError.message("虚拟机控制请求发送失败。") }
        offset += count
      }
    }
    while true {
      let response = try readObject()
      if response["id"] as? Int == id {
        if let error = response["error"] as? [String: Any] {
          throw VMError.message("虚拟机拒绝了控制请求：\(error["desc"] ?? error)")
        }
        return response["return"] ?? [:]
      }
    }
  }
  func object(_ command: String, _ arguments: [String: Any] = [:]) throws -> [String: Any] {
    guard let value = try execute(command, arguments) as? [String: Any] else { throw VMError.message("控制接口返回类型异常。") }
    return value
  }
  func waitForMigration() throws {
    let deadline = Date().addingTimeInterval(600)
    while Date() < deadline {
      let value = try object("query-migrate")
      switch value["status"] as? String {
      case "completed": return
      case "failed", "cancelled": throw VMError.message("保存或恢复失败：\(value["error-desc"] ?? value["status"] ?? "未知错误")")
      default: Thread.sleep(forTimeInterval: 0.25)
      }
    }
    throw VMError.message("保存或恢复超过 10 分钟，操作未完成。")
  }
  func saveState(to file: URL, commit: () throws -> Void) throws {
    let blockers = try object("query-migrate")["blocked-reasons"] as? [String] ?? []
    guard blockers.isEmpty else { throw VMError.message(blockers.joined(separator: "\n")) }
    guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
      throw VMError.message("无法创建暂停文件，请检查磁盘空间和权限。")
    }
    try execute("stop")
    do {
      try execute("migrate", Self.fileChannel(file))
      try waitForMigration()
      let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }; try handle.synchronize()
      try commit()
    } catch {
      _ = try? execute("migrate_cancel")
      let deadline = Date().addingTimeInterval(30)
      while Date() < deadline {
        let state = try object("query-migrate")["status"] as? String
        if state == "cancelled" || state == "failed" || state == "completed" || state == nil { break }
        Thread.sleep(forTimeInterval: 0.25)
      }
      try execute("cont")
      guard try object("query-status")["running"] as? Bool == true else { throw error }
      try? FileManager.default.removeItem(at: file)
      throw error
    }
  }
  static func fileChannel(_ url: URL) -> [String: Any] {
    ["channels": [["channel-type": "main", "addr": ["transport": "file", "filename": url.path, "offset": 0]]]]
  }
}

enum QMP {
  static func powerDown(path: String) throws {
    try QMPConnection(path: path).execute("system_powerdown")
  }
}
