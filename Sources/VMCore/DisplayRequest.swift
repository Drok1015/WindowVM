import Foundation

public struct DisplayRequest: Codable, Equatable {
  public let id: String
  public let width: Int
  public let height: Int
  public let intervalMs: Int
  public var isValid: Bool {
    !id.isEmpty && id.count <= 100 && (640...3840).contains(width) && (480...2160).contains(height) && intervalMs == 800
  }
}

public struct DisplayAcknowledgement: Codable {
  public let id: String
  public let width: Int
  public let height: Int
  public let success: Bool
  public let error: String?
}
