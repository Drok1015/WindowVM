import Foundation

public struct VMConfiguration: Codable, Equatable {
  public var memoryGiB = 8
  public var cpuCount = 4
  public var diskGiB = 80
  public var installerISO = ""
  public var driverISO = ""
  public var mountInstaller = true
  public var clipboardEnabled = true
  public var forwardHostPort = 18080
  public var forwardGuestPort = 8080
  public init() {}
  public func validate() throws {
    guard (4...24).contains(memoryGiB), (2...12).contains(cpuCount),
          (64...512).contains(diskGiB), (1024...65535).contains(forwardHostPort),
          (1...65535).contains(forwardGuestPort) else {
      throw VMError.message("资源或端口配置超出允许范围。")
    }
    for path in [mountInstaller ? installerISO : "", driverISO] where !path.isEmpty {
      guard path.lowercased().hasSuffix(".iso"), FileManager.default.fileExists(atPath: path) else {
        throw VMError.message("找不到 ISO 镜像：\(path)")
      }
      guard !path.contains(","), !path.contains("\n") else {
        throw VMError.message("镜像路径不能包含逗号或换行，请移动文件后重试。")
      }
    }
  }
}

public enum VMError: LocalizedError {
  case message(String)
  public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

public struct LaunchPlan {
  public let arguments: [String]
  public init(configuration c: VMConfiguration, directory: URL, firmware: String) throws {
    try c.validate()
    guard !directory.path.contains(","), !firmware.contains(",") else {
      throw VMError.message("虚拟机目录或固件路径不能包含逗号。")
    }
    func path(_ name: String) -> String { directory.appendingPathComponent(name).path }
    var a = ["-L", "/opt/homebrew/share/qemu", "-name", "WindowVM - Windows 11 ARM", "-machine", "virt,highmem=on,gic-version=3",
      "-accel", "hvf", "-cpu", "host", "-smp", String(c.cpuCount), "-m", String(c.memoryGiB * 1024),
      "-drive", "if=pflash,format=raw,readonly=on,file=\(firmware)",
      "-drive", "if=pflash,format=raw,file=\(path("efi-vars.fd"))",
      "-drive", "if=none,id=system,format=qcow2,file=\(path("windows.qcow2"))",
      "-device", "nvme,drive=system,serial=WINDOWVM001,bootindex=1",
      "-device", "ramfb", "-device", "virtio-gpu-pci,id=display0,edid=on,xres=1280,yres=800", "-device", "qemu-xhci", "-device", "usb-kbd", "-device", "usb-tablet",
      "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:\(c.forwardHostPort)-:\(c.forwardGuestPort)",
      "-device", "virtio-net-pci,netdev=net0",
      "-chardev", "socket,id=chrtpm,path=\(path("tpm.sock"))",
      "-tpmdev", "emulator,id=tpm0,chardev=chrtpm", "-device", "tpm-tis-device,tpmdev=tpm0,ppi=off",
      "-qmp", "unix:\(path("qmp.sock")),server=on,wait=off",
      "-pidfile", path("qemu.pid"), "-display", "cocoa,zoom-to-fit=on", "-boot", "menu=on"]
    func attach(_ iso: String, id: String, boot: Bool = false) {
      a += ["-drive", "if=none,id=\(id),media=cdrom,readonly=on,file=\(iso)",
            "-device", "usb-storage,drive=\(id)" + (boot ? ",bootindex=0" : "")]
    }
    if c.mountInstaller && !c.installerISO.isEmpty { attach(c.installerISO, id: "installer", boot: true) }
    if !c.driverISO.isEmpty { attach(c.driverISO, id: "drivers") }
    attach(path("guest-tools.iso"), id: "tools")
    arguments = a
  }
}

public struct ClipboardSnapshot: Codable, Equatable {
  public var version: Int
  public var text: String
}
public struct ClipboardUpdate: Codable {
  public var baseVersion: Int
  public var text: String
}
/// Access on one serial executor. Versions prevent delayed guest writes from replacing newer copies.
public struct ClipboardState {
  public private(set) var snapshot = ClipboardSnapshot(version: 0, text: "")
  public init() {}
  public mutating func observe(_ text: String) {
    if text != snapshot.text { snapshot = ClipboardSnapshot(version: snapshot.version + 1, text: text) }
  }
  public mutating func accept(_ update: ClipboardUpdate) -> Bool {
    guard update.baseVersion == snapshot.version else { return false }
    observe(update.text)
    return true
  }
}
