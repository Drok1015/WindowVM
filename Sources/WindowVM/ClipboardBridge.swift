import AppKit
import Network
import VMCore

@MainActor final class ClipboardBridge: ObservableObject {
  @Published var status = "未启动"
  @Published var displayStatus = "等待 Windows 显示配套程序"
  private var stateDirectory: URL?
  private var clipboardEnabled = true
  private let pasteboard: NSPasteboard
  init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
  private var listener: NWListener?
  private var timer: Timer?
  private var state = ClipboardState()
  private var changeCount = -1
  private var token = ""
  private var lastContact: Date?
  private var connections: [UUID: NWConnection] = [:]
  private let queue = DispatchQueue(label: "WindowVM.clipboard")

  func start(token: String, port: UInt16, directory: URL? = nil, clipboardEnabled: Bool = true) async throws -> UInt16 {
    stop()
    self.token = token
    self.stateDirectory = directory
    self.clipboardEnabled = clipboardEnabled
    state = ClipboardState()
    changeCount = -1
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    let listener = try NWListener(using: parameters)
    self.listener = listener
    return try await withCheckedThrowingContinuation { continuation in
      var completed = false
      listener.stateUpdateHandler = { [weak self] event in
        Task { @MainActor in
          guard !completed else { return }
          switch event {
          case .ready:
            completed = true
            guard let port = listener.port else {
              continuation.resume(throwing: VMError.message("无法分配剪贴板端口。")); return
            }
            self?.status = "等待 Windows 配套程序"
            self?.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
              Task { @MainActor in self?.readPasteboard() }
            }
            continuation.resume(returning: port.rawValue)
          case .failed(let error):
            completed = true
            continuation.resume(throwing: error)
          case .cancelled:
            completed = true
            continuation.resume(throwing: VMError.message("剪贴板服务已取消。"))
          default: break
          }
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        Task { @MainActor in self?.accept(connection) }
      }
      listener.start(queue: queue)
    }
  }

  func stop() {
    listener?.cancel(); listener = nil
    timer?.invalidate(); timer = nil
    for connection in connections.values { connection.cancel() }
    connections.removeAll()
    status = "未启动"
    lastContact = nil
  }

  private func readPasteboard() {
    if let lastContact, Date().timeIntervalSince(lastContact) > 5 { status = "等待 Windows 配套程序" }
    guard clipboardEnabled else { return }
    let pb = pasteboard
    guard pb.changeCount != changeCount else { return }
    changeCount = pb.changeCount
    // Non-text clipboard items are outside the protocol; clear old shared text.
    let text = pb.string(forType: .string) ?? ""
    if text.utf8.count <= 512 * 1024 { state.observe(text) }
  }

  private func accept(_ connection: NWConnection) {
    guard connections.count < 16 else { connection.cancel(); return }
    let id = UUID()
    connections[id] = connection
    connection.start(queue: queue)
    receive(connection, id: id, buffer: Data())
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
      self?.connections.removeValue(forKey: id)?.cancel()
    }
  }

  private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, finished, error in
      Task { @MainActor in
        guard let self, self.connections[id] != nil else { return }
        var accumulated = buffer
        if let data { accumulated.append(data) }
        guard accumulated.count <= 1024 * 1024 else {
          self.reply(connection, id: id, code: 413, body: Data()); return
        }
        if let split = accumulated.range(of: Data("\r\n\r\n".utf8)) {
          let header = String(decoding: accumulated[..<split.lowerBound], as: UTF8.self)
          let lines = header.components(separatedBy: "\r\n")
          var headers: [String: String] = [:]
          for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { headers[String(parts[0]).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
          }
          guard headers["authorization"] == "Bearer \(self.token)" else {
            self.reply(connection, id: id, code: 401, body: Data()); return
          }
          guard headers["transfer-encoding"] == nil,
                let length = Int(headers["content-length"] ?? "0"), (0...768 * 1024).contains(length) else {
            self.reply(connection, id: id, code: 400, body: Data()); return
          }
          let body = Data(accumulated[split.upperBound...])
          if body.count >= length {
            self.handle(connection, id: id, request: lines.first ?? "", body: body.prefix(length)); return
          }
        }
        if finished || error != nil { self.connections.removeValue(forKey: id)?.cancel(); return }
        self.receive(connection, id: id, buffer: accumulated)
      }
    }
  }

  private func handle(_ connection: NWConnection, id: UUID, request: String, body: Data) {
    readPasteboard()
    let method = request.split(separator: " ").prefix(2).joined(separator: " ")
    if method == "GET /display" {
      guard let directory = stateDirectory,
            let data = try? Data(contentsOf: directory.appendingPathComponent("display-request.json")),
            let request = try? JSONDecoder().decode(DisplayRequest.self, from: data), request.isValid else {
        reply(connection, id: id, code: 200, body: Data("null".utf8)); return
      }
      reply(connection, id: id, code: 200, body: data); return
    }
    if method == "POST /display" {
      guard let directory = stateDirectory,
            let acknowledgement = try? JSONDecoder().decode(DisplayAcknowledgement.self, from: body),
            let data = try? Data(contentsOf: directory.appendingPathComponent("display-request.json")),
            let current = try? JSONDecoder().decode(DisplayRequest.self, from: data),
            acknowledgement.id == current.id else {
        reply(connection, id: id, code: 409, body: Data()); return
      }
      displayStatus = (acknowledgement.success && acknowledgement.width == current.width && acknowledgement.height == current.height) ? "已适应 \(acknowledgement.width) × \(acknowledgement.height) · 800ms" : "分辨率调整失败：\(acknowledgement.error ?? "未知错误")"
      try? body.write(to: directory.appendingPathComponent("display-status.json"), options: .atomic)
      if acknowledgement.success && acknowledgement.width == current.width && acknowledgement.height == current.height {
        try? Data("virtio-gpu-v1".utf8).write(to: directory.appendingPathComponent("display-configured"), options: .atomic)
      }
      reply(connection, id: id, code: 200, body: Data("{}".utf8)); return
    }
    guard clipboardEnabled else { reply(connection, id: id, code: 403, body: Data()); return }
    var code = 200
    switch method {
    case "GET /clipboard": break
    case "PUT /clipboard":
      guard let update = try? JSONDecoder().decode(ClipboardUpdate.self, from: body),
            update.text.utf8.count <= 512 * 1024 else {
        reply(connection, id: id, code: 400, body: Data()); return
      }
      guard state.accept(update) else {
        reply(connection, id: id, code: 409, body: (try? JSONEncoder().encode(state.snapshot)) ?? Data()); return
      }
      pasteboard.clearContents()
      pasteboard.setString(update.text, forType: .string)
      changeCount = pasteboard.changeCount
    default: code = 404
    }
    if code == 200 { lastContact = Date(); status = "已连接 · 双向文本同步" }
    reply(connection, id: id, code: code, body: (try? JSONEncoder().encode(state.snapshot)) ?? Data())
  }

  private func reply(_ connection: NWConnection, id: UUID, code: Int, body: Data) {
    let header = "HTTP/1.1 \(code) Response\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
    connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] _ in
      connection.cancel()
      Task { @MainActor in self?.connections.removeValue(forKey: id) }
    })
  }
}
