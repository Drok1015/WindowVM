import Foundation

/// Maps the host's explicit web proxy to the guest's QEMU NAT gateway.
public struct HostProxy: Codable, Equatable {
  public let server: String
  public let bypass: String
  public let testProxy: String

  public static func from(settings: [String: Any]) -> HostProxy? {
    func endpoint(_ prefix: String) -> String? {
      guard (settings[prefix + "Enable"] as? NSNumber)?.boolValue == true,
            let host = settings[prefix + "Proxy"] as? String, !host.isEmpty,
            host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
            !host.contains(";"),
            let port = settings[prefix + "Port"] as? Int, (1...65535).contains(port) else { return nil }
      let mapped = ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) ? "10.0.2.2" : host
      return (mapped.contains(":") ? "[\(mapped)]" : mapped) + ":\(port)"
    }
    let http = endpoint("HTTP"), https = endpoint("HTTPS")
    let parts = [("http", http), ("https", https)].compactMap { name, value in value.map { "\(name)=\($0)" } }
    guard let test = https ?? http else { return nil }
    let exceptions = settings["ExceptionsList"] as? [String] ?? []
    let bypass = (["<local>", "localhost", "127.*", "10.*", "192.168.*", "172.16.*", "172.17.*", "172.18.*", "172.19.*", "172.2*", "172.30.*", "172.31.*"] + exceptions.flatMap { $0.split(separator: ",").map(String.init) }).joined(separator: ";")
    return HostProxy(server: parts.joined(separator: ";"), bypass: bypass, testProxy: "http://" + test)
  }
}
