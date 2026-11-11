import AppKit
import VMCore
import SystemConfiguration

func runCommand(_ executable: String, _ arguments: [String]) async throws -> String {
  try await Task.detached {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe; process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: output, as: UTF8.self)
    guard process.terminationStatus == 0 else { throw VMError.message(text.isEmpty ? "命令执行失败：\(executable)" : text) }
    return text
  }.value
}

@MainActor final class VMController: ObservableObject {
  @Published var configuration = VMConfiguration()
  @Published var running = false
  @Published var suspended = false
  @Published var busy = false
  @Published var status = "准备安装 Windows 11 ARM"
  @Published var error: String?
  @Published var diskExists = false
  let clipboard = ClipboardBridge()
  let directory: URL
  private var lockFD: Int32 = -1
  private var qemu: Process?
  private var tpm: Process?
  private var logHandle: FileHandle?
  private let clipboardPort: UInt16 = 47831
  private var token = ""
  var onStopped: (() -> Void)?
  private var lifecycleTimer: Timer?
  private var lastLifecycleID = ""
  private var activeArguments: [String] = []
  private var activeFirmware = ""
  private var pendingSuspend: SuspendedState?
  private var restoring = false
  private var suspendCompletion: ((Bool) -> Void)?
  private var stateURL: URL { directory.appendingPathComponent("suspend.bin") }
  private var manifestURL: URL { directory.appendingPathComponent("suspend.json") }
  private var pendingURL: URL { directory.appendingPathComponent("suspend-pending.json") }
  private var resumingURL: URL { directory.appendingPathComponent("resume-in-progress.json") }
  var qemuPath: String {
    Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/WindowVM Engine.app/Contents/MacOS/WindowVMEngine").path
  }
  private var engineBinary: String { URL(fileURLWithPath: qemuPath).deletingLastPathComponent().appendingPathComponent("QEMU").path }
  var dependenciesReady: Bool {
    [qemuPath, engineBinary, "/opt/homebrew/bin/qemu-img", "/opt/homebrew/bin/swtpm"].allSatisfy { FileManager.default.isExecutableFile(atPath: $0) }
  }

  init() {
    directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("WindowVM/Windows11", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      if let data = try? Data(contentsOf: directory.appendingPathComponent("configuration.json")) {
        configuration = try JSONDecoder().decode(VMConfiguration.self, from: data)
      }
      let tokenURL = directory.appendingPathComponent("clipboard-token")
      if let existing = try? String(contentsOf: tokenURL, encoding: .utf8), existing.count >= 32 { token = existing }
      else {
        token = UUID().uuidString + UUID().uuidString
        try token.write(to: tokenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
      }
    } catch { self.error = error.localizedDescription }
    suspended = FileManager.default.fileExists(atPath: manifestURL.path)
    if suspended { status = "已暂停 · 下次打开将继续上次操作" }
    lifecycleTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.checkLifecycleRequest() }
    }
    diskExists = FileManager.default.fileExists(atPath: directory.appendingPathComponent("windows.qcow2").path)
  }

  func save() throws {
    try configuration.validate()
    try JSONEncoder().encode(configuration).write(to: directory.appendingPathComponent("configuration.json"), options: .atomic)
  }

  func chooseISO(driver: Bool) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.init(filenameExtension: "iso")!]
    panel.canChooseDirectories = false
    panel.message = driver ? "选择包含 ARM64 网络驱动的 VirtIO ISO" : "请选择 Windows 11 ARM64 ISO，不能使用 x64 镜像"
    if panel.runModal() == .OK, let url = panel.url {
      if driver { configuration.driverISO = url.path }
      else { configuration.installerISO = url.path; configuration.mountInstaller = true }
    }
  }

  func start() {
    guard !busy, !running else { return }
    busy = true; error = nil
    Task<Void, Never> { [self] in
      do {
        lockFD = open(directory.appendingPathComponent("run.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
          if lockFD >= 0 { close(lockFD); lockFD = -1 }
          throw VMError.message("该虚拟机已被其他应用实例使用。")
        }
        let pidURL = directory.appendingPathComponent("qemu.pid")
        if let savedPID = try? String(contentsOf: pidURL, encoding: .utf8),
           let pid = Int32(savedPID.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
           kill(pid, 0) == 0 || errno == EPERM {
          throw VMError.message("上次启动的虚拟机仍在运行（PID \(pid)）。请先关闭它的 Windows/QEMU 窗口，再重新启动。")
        }
        if FileManager.default.fileExists(atPath: pidURL.path) { try FileManager.default.removeItem(at: pidURL) }
        guard dependenciesReady else { throw VMError.message("缺少 QEMU 或 swtpm，请运行 scripts/setup.sh。") }
        if !diskExists && (!configuration.mountInstaller || configuration.installerISO.isEmpty) {
          throw VMError.message("请先下载并选择 Windows 11 ARM64 ISO。")
        }
        if FileManager.default.fileExists(atPath: pendingURL.path) || FileManager.default.fileExists(atPath: resumingURL.path) || (!suspended && FileManager.default.fileExists(atPath: stateURL.path)) {
          throw VMError.message("上次保存或恢复被中断。已保留状态文件并阻止冷启动，避免丢失上次操作；请查看运行日志后处理。")
        }
        let checkpoint = suspended ? try JSONDecoder().decode(SuspendedState.self, from: Data(contentsOf: manifestURL)) : nil
        try save()
        status = "正在准备磁盘与固件…"
        guard let resources = Bundle.main.resourceURL else { throw VMError.message("无法定位应用固件资源。") }
        let share = resources.appendingPathComponent("Firmware")
        let code = share.appendingPathComponent("AAVMF_CODE.ms.fd")
        let varsSource = share.appendingPathComponent("AAVMF_VARS.ms.fd")
        guard FileManager.default.fileExists(atPath: code.path), FileManager.default.fileExists(atPath: varsSource.path) else {
          throw VMError.message("找不到支持安全启动的 ARM UEFI 固件，请重新构建应用。")
        }
        let vars = directory.appendingPathComponent("efi-vars.fd")
        if !FileManager.default.fileExists(atPath: vars.path) { try FileManager.default.copyItem(at: varsSource, to: vars) }
        if !diskExists {
          let temporary = directory.appendingPathComponent("windows.creating.qcow2")
          if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
          _ = try await runCommand("/opt/homebrew/bin/qemu-img", ["create", "-f", "qcow2", temporary.path, "\(configuration.diskGiB)G"])
          try FileManager.default.moveItem(at: temporary, to: directory.appendingPathComponent("windows.qcow2"))
          diskExists = true
        }
        _ = try await clipboard.start(token: token, port: clipboardPort, directory: directory, clipboardEnabled: configuration.clipboardEnabled)
        if checkpoint == nil { try await makeGuestTools() }
        let plan = try LaunchPlan(configuration: configuration, directory: directory, firmware: code.path)
        if let checkpoint {
          try checkpoint.validate(arguments: plan.arguments, configuration: configuration, engine: engineBinary, firmware: code.path)
        }
        activeArguments = plan.arguments; activeFirmware = code.path
        for name in ["qmp.sock", "tpm.sock", "tpm.sock.ctrl", "lifecycle-request.json", "lifecycle-response.json"] {
          let path = directory.appendingPathComponent(name)
          if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        }
        let tpmDirectory = directory.appendingPathComponent("tpm", isDirectory: true)
        try FileManager.default.createDirectory(at: tpmDirectory, withIntermediateDirectories: true)
        let tpmProcess = Process()
        tpmProcess.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/swtpm")
        tpmProcess.arguments = ["socket", "--tpm2", "--tpmstate", "dir=\(tpmDirectory.path)",
          "--ctrl", "type=unixio,path=\(directory.appendingPathComponent("tpm.sock").path)", "--flags", "not-need-init"]
        let logURL = directory.appendingPathComponent("last-run.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        logHandle = log
        tpmProcess.standardOutput = log; tpmProcess.standardError = log
        try tpmProcess.run(); tpm = tpmProcess
        for _ in 0..<50 {
          if FileManager.default.fileExists(atPath: directory.appendingPathComponent("tpm.sock").path) { break }
          try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard tpmProcess.isRunning, FileManager.default.fileExists(atPath: directory.appendingPathComponent("tpm.sock").path) else {
          throw VMError.message("TPM 启动失败，请查看运行日志。")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: qemuPath)
        process.arguments = plan.arguments + (checkpoint == nil ? [] : ["-incoming", "defer", "-S"])
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
        environment["WINDOWVM_DISPLAY_LIBRARY"] = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/WindowVM Engine.app/Contents/Resources/WindowVMDisplay.dylib").path
        environment["WINDOWVM_STATE_DIR"] = directory.path
        process.environment = environment
        process.standardOutput = log; process.standardError = log
        process.terminationHandler = { [weak self] process in
          Task { @MainActor in self?.didStop(pid: process.processIdentifier, code: process.terminationStatus) }
        }
        qemu = process
        try process.run()
        running = true
        if checkpoint != nil {
          restoring = true
          status = "正在恢复上次暂停的 Windows…"
          let path = directory.appendingPathComponent("qmp.sock").path
          for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: path) { break }
            guard process.isRunning else { throw VMError.message("恢复引擎启动失败，保存状态仍保留。") }
            try await Task.sleep(nanoseconds: 100_000_000)
          }
          let file = stateURL, journal = resumingURL
          try await Task.detached {
            let control = try QMPConnection(path: path)
            try control.execute("migrate-incoming", QMPConnection.fileChannel(file))
            try control.waitForMigration()
            // Before the first resumed instruction, mark this checkpoint as consumed.
            // An interrupted acknowledgement must never replay stale memory on a newer disk.
            try SuspendedState.write(["consumedAt": Date()], to: journal)
            try control.execute("cont")
            guard try control.object("query-status")["running"] as? Bool == true else { throw VMError.message("Windows 尚未恢复运行。") }
          }.value
          suspended = false; restoring = false
          do {
            try FileManager.default.removeItem(at: manifestURL)
            try FileManager.default.removeItem(at: stateURL)
            try FileManager.default.removeItem(at: resumingURL)
          } catch {
            // The guest is already running: a cleanup error must never kill it.
            self.error = "Windows 已恢复，但旧保存文件清理未完成：\(error.localizedDescription)"
          }
        }
        busy = false
        status = "虚拟机运行中 · 关闭 Engine 窗口会保存并暂停"
      } catch {
        if qemu?.isRunning == true {
          // Incoming failures never fall back to booting Windows against saved memory.
          let path = directory.appendingPathComponent("qmp.sock").path
          _ = try? await Task.detached { _ = try QMPConnection(path: path).execute("quit") }.value
          if qemu?.isRunning == true { qemu?.terminate() }
        } else { cleanup() }
        busy = false
        status = "启动未完成"
        self.error = error.localizedDescription
      }
    }
  }

  private func makeGuestTools() async throws {
    guard let resources = Bundle.main.resourceURL else { throw VMError.message("无法定位应用资源。") }
    let source = resources.appendingPathComponent("Guest")
    let staging = directory.appendingPathComponent("guest-tools", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    for file in ["ClipboardAgent.ps1", "Install.ps1", "Install.cmd", "InstallDisplay.ps1", "InstallDisplay.cmd", "DisplayControl.cs", "UseHostProxy.ps1", "UseHostProxy.cmd", "RestoreProxy.cmd"] {
      let target = staging.appendingPathComponent(file)
      if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
      try FileManager.default.copyItem(at: source.appendingPathComponent(file), to: target)
    }
    let driverTarget = staging.appendingPathComponent("DisplayDriver")
    if FileManager.default.fileExists(atPath: driverTarget.path) { try FileManager.default.removeItem(at: driverTarget) }
    try FileManager.default.copyItem(at: source.appendingPathComponent("DisplayDriver"), to: driverTarget)
    var json: [String: Any] = ["token": token, "port": clipboardPort]
    if let settings = SCDynamicStoreCopyProxies(nil) as? [String: Any], let proxy = HostProxy.from(settings: settings) {
      json["proxy"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(proxy))
    }
    try JSONSerialization.data(withJSONObject: json).write(to: staging.appendingPathComponent("bridge.json"), options: .atomic)
    _ = try await runCommand("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-default-volume-name", "WINDOWVM_TOOLS", "-o", directory.appendingPathComponent("guest-tools.iso").path, staging.path, "-ov"])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("guest-tools.iso").path)
  }

  private func checkLifecycleRequest() {
    struct Request: Decodable { var id: String; var pid: Int32; var action: String }
    let requestURL = directory.appendingPathComponent("lifecycle-request.json")
    guard let data = try? Data(contentsOf: requestURL), let request = try? JSONDecoder().decode(Request.self, from: data),
          request.id != lastLifecycleID, request.pid == qemu?.processIdentifier, request.action == "suspend" else { return }
    lastLifecycleID = request.id
    let responseURL = directory.appendingPathComponent("lifecycle-response.json")
    if busy {
      try? SuspendedState.write(["id": request.id, "status": "error", "error": "虚拟机正在执行其他操作，请稍后再试。"], to: responseURL)
      return
    }
    try? SuspendedState.write(["id": request.id, "status": "saving"], to: responseURL)
    suspend { success in
      if !success {
        try? SuspendedState.write(["id": request.id, "status": "error", "error": self.error ?? "保存未完成，窗口保持打开。"], to: responseURL)
      }
    }
  }

  func suspend(completion: ((Bool) -> Void)? = nil) {
    guard running, !busy, let process = qemu, process.isRunning else { completion?(false); return }
    busy = true; error = nil; suspendCompletion = completion
    status = "正在保存 Windows 运行状态，请勿强制退出…"
    let path = directory.appendingPathComponent("qmp.sock").path
    let file = stateURL, pending = pendingURL
    let arguments = activeArguments, config = configuration, engine = engineBinary, firmware = activeFirmware
    Task {
      do {
        let checkpoint = try await Task.detached { () throws -> SuspendedState in
          let control = try QMPConnection(path: path)
          let checkpoint = SuspendedState(arguments: arguments, configuration: config,
            engineHash: try SuspendedState.digest(engine), tpmHash: try SuspendedState.digest("/opt/homebrew/bin/swtpm"),
            firmwareHash: try SuspendedState.digest(firmware))
          try control.saveState(to: file) {
            // Durable intent before exiting: a crash here blocks unsafe cold boot.
            try SuspendedState.write(checkpoint, to: pending)
          }
          return checkpoint
        }.value
        pendingSuspend = checkpoint
        // QMP quit is sent only after a complete, durable save. Window close itself never kills QEMU.
        try await Task.detached { _ = try QMPConnection(path: path).execute("quit") }.value
      } catch {
        // If quit failed after saving, keep the paused engine and its checkpoint intact.
        pendingSuspend = nil
        if !FileManager.default.fileExists(atPath: file.path) { try? FileManager.default.removeItem(at: pending) }
        busy = false; status = "暂停未完成 · 已保留虚拟机窗口"
        self.error = error.localizedDescription
        let callback = suspendCompletion; suspendCompletion = nil; callback?(false)
      }
    }
  }

  func requestShutdown() {
    guard running, !busy else { return }
    busy = true
    let path = directory.appendingPathComponent("qmp.sock").path
    Task {
      do {
        try await Task.detached { try QMP.powerDown(path: path) }.value
        status = "已请求 Windows 关机，正在等待…"
      } catch { self.error = error.localizedDescription }
      busy = false
    }
  }

  func forceStop() {
    guard !busy, let qemu, qemu.isRunning else { return }
    qemu.terminate()
    status = "正在强制停止…"
    // QEMU may treat SIGTERM as a request to power down; escalate only after explicit force-stop.
    let pid = qemu.processIdentifier
    Task {
      try? await Task.sleep(nanoseconds: 5_000_000_000)
      if self.qemu?.processIdentifier == pid, qemu.isRunning { kill(pid, SIGKILL) }
    }
  }

  private func didStop(pid: Int32, code: Int32) {
    guard qemu?.processIdentifier == pid else { return }
    let checkpoint = pendingSuspend
    pendingSuspend = nil
    cleanup()
    busy = false; running = false
    if var checkpoint, code == 0 {
      do {
        try checkpoint.seal(directory: directory, stateFile: stateURL)
        try SuspendedState.write(checkpoint, to: manifestURL)
        try FileManager.default.removeItem(at: pendingURL)
        if FileManager.default.fileExists(atPath: resumingURL.path) { try FileManager.default.removeItem(at: resumingURL) }
        suspended = true; status = "已暂停 · 下次打开将继续上次操作"
        let callback = suspendCompletion; suspendCompletion = nil; callback?(true)
      } catch {
        self.error = "保存文件已保留，但暂停状态未能完成登记：\(error.localizedDescription)"
        status = "暂停登记未完成"
        let callback = suspendCompletion; suspendCompletion = nil; callback?(false)
      }
    } else {
      status = restoring ? "恢复未完成 · 已保留保存状态" : (code == 0 ? "虚拟机已关闭" : "虚拟机已停止（\(code)）")
      if code != 0 && !restoring { error = "虚拟机异常停止，请点击“运行日志”查看详情。" }
      restoring = false
      let callback = suspendCompletion; suspendCompletion = nil; callback?(false)
    }
    onStopped?()
  }
  private func cleanup() {
    if tpm?.isRunning == true { tpm?.terminate(); tpm?.waitUntilExit() }
    if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
    if qemu != nil { try? FileManager.default.removeItem(at: directory.appendingPathComponent("qemu.pid")) }
    tpm = nil; qemu = nil
    try? logHandle?.close(); logHandle = nil
    clipboard.stop()
  }
  func showFiles() { NSWorkspace.shared.open(directory) }
  func showLog() { NSWorkspace.shared.open(directory.appendingPathComponent("last-run.log")) }
}
