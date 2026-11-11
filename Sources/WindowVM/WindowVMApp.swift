import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  var controller: VMController?
  private weak var managementWindow: NSWindow?
  private let managementDelegate = ManagementWindowDelegate()
  func attachManagementWindow(_ window: NSWindow) {
    managementWindow = window
    if window.delegate !== managementDelegate {
      managementDelegate.original = window.delegate
      window.delegate = managementDelegate
    }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationDidFinishLaunching(_ notification: Notification) {
    if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
       let icon = NSImage(contentsOf: url) {
      NSApp.applicationIconImage = icon
    }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    managementWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    if controller?.suspended == true { controller?.start() }
    return true
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let controller else { return .terminateNow }
    if controller.busy && !controller.running { return .terminateCancel }
    guard controller.running else { return .terminateNow }
    if controller.busy { return .terminateCancel }
    controller.suspend { success in NSApp.reply(toApplicationShouldTerminate: success) }
    return .terminateLater
  }
}

@main struct WindowVMApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var controller = VMController()
  var body: some Scene {
    WindowGroup("WindowVM") {
      MainView(controller: controller)
        .background(ManagementWindowReader { delegate.attachManagementWindow($0) })
        .onAppear {
          delegate.controller = controller
          if controller.suspended { controller.start() }
        }
    }.defaultSize(width: 880, height: 760)
    .commands { CommandGroup(replacing: .newItem) {} }
  }
}

struct MainView: View {
  @ObservedObject var controller: VMController
  @State private var confirmStop = false
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 14) {
        if let icon = NSImage(named: "AppIcon") {
          Image(nsImage: icon).resizable().frame(width: 52, height: 52)
        } else {
          Image(systemName: "desktopcomputer").font(.system(size: 36)).foregroundStyle(.blue)
        }
        VStack(alignment: .leading, spacing: 5) {
          Text("Windows，在你的 Mac 上").font(.title2.bold())
          Text("WindowVM · Windows 11 ARM64").foregroundStyle(.secondary)
        }
        Spacer()
        Label(controller.running ? "运行中" : (controller.suspended ? "已暂停" : "已关闭"), systemImage: controller.running ? "circle.fill" : "circle")
          .foregroundStyle(controller.running ? .green : .secondary)
      }
      Form {
        Section("1 · 安装镜像") {
          HStack {
            Button("微软官方下载") { openURL("https://www.microsoft.com/zh-cn/software-download/windows11arm64") }
            Button("选择 Windows ISO…") { controller.chooseISO(driver: false) }
            Spacer()
            Text(controller.configuration.installerISO.isEmpty ? "尚未选择" : URL(fileURLWithPath: controller.configuration.installerISO).lastPathComponent)
              .lineLimit(1).truncationMode(.middle).help(controller.configuration.installerISO)
          }
          Toggle("挂载安装镜像（安装完成并关机后取消）", isOn: $controller.configuration.mountInstaller)
          HStack {
            Button("网络驱动下载") { openURL("https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso") }
            Button("选择驱动 ISO…") { controller.chooseISO(driver: true) }
            Spacer()
            Text(controller.configuration.driverISO.isEmpty ? "安装联网前需要 ARM64 网卡驱动" : URL(fileURLWithPath: controller.configuration.driverISO).lastPathComponent)
              .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
          }
        }
        Section("2 · 虚拟机资源") {
          HStack {
            Stepper("CPU：\(controller.configuration.cpuCount) 核", value: $controller.configuration.cpuCount, in: 2...12)
            Spacer(minLength: 30)
            Stepper("内存：\(controller.configuration.memoryGiB) GB", value: $controller.configuration.memoryGiB, in: 4...24)
          }
          Stepper("磁盘：\(controller.configuration.diskGiB) GB（按实际使用占空间）", value: $controller.configuration.diskGiB, in: 64...512, step: 16)
            .disabled(controller.diskExists)
        }
        Section("3 · 网络与剪贴板") {
          LabeledContent("Windows → Mac", value: "10.0.2.2（Mac 服务需监听 IPv4）")
          HStack {
            Text("Mac → Windows")
            Spacer()
            Text("127.0.0.1:")
            TextField("宿主端口", value: $controller.configuration.forwardHostPort, format: .number.grouping(.never)).frame(width: 72)
            Text("→")
            TextField("Windows 端口", value: $controller.configuration.forwardGuestPort, format: .number.grouping(.never)).frame(width: 72)
          }
          Toggle("双向共享文字剪贴板（支持中文）", isOn: $controller.configuration.clipboardEnabled)
          Text("Windows 安装完成后，在 WINDOWVM_TOOLS 光盘双击 Install.cmd。配套程序会在登录时启动；仅虚拟机运行期间同步文字。")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .disabled(controller.running || controller.busy || controller.suspended)
      HStack {
        VStack(alignment: .leading, spacing: 5) {
          Text(controller.status).font(.callout)
          ClipboardStatus(bridge: controller.clipboard)
        }
        Spacer()
        if controller.busy { ProgressView().controlSize(.small) }
        if controller.running {
          Button("强制停止", role: .destructive) { confirmStop = true }.disabled(controller.busy)
          Button("保存并暂停") { controller.suspend() }.disabled(controller.busy)
          Button("正常关机") { controller.requestShutdown() }.disabled(controller.busy)
        } else {
          Button(controller.suspended ? "继续 Windows" : (controller.diskExists ? "启动 Windows" : "创建并安装 Windows")) { controller.start() }
            .buttonStyle(.borderedProminent).disabled(controller.busy)
        }
      }
      HStack {
        Button("虚拟机文件") { controller.showFiles() }
        Button("运行日志") { controller.showLog() }
        Button("安装说明") {
          if let url = Bundle.main.url(forResource: "README", withExtension: "html") { NSWorkspace.shared.open(url) }
        }
        Spacer()
        Text(controller.dependenciesReady ? "QEMU · HVF · TPM 2.0" : "请先安装 QEMU / swtpm")
          .font(.caption).foregroundStyle(.secondary)
      }.controlSize(.small)
    }
    .padding(24)
    .frame(minWidth: 800, minHeight: 700)
    .alert("操作未完成", isPresented: Binding(get: { controller.error != nil }, set: { if !$0 { controller.error = nil } })) {
      Button("好") { controller.error = nil }
    } message: { Text(controller.error ?? "") }
    .confirmationDialog("强制停止可能造成 Windows 未保存内容丢失或磁盘损坏。", isPresented: $confirmStop) {
      Button("强制停止", role: .destructive) { controller.forceStop() }
      Button("取消", role: .cancel) {}
    }
  }
  private func openURL(_ string: String) { if let url = URL(string: string) { NSWorkspace.shared.open(url) } }
}
struct ClipboardStatus: View {
  @ObservedObject var bridge: ClipboardBridge
  var body: some View { VStack(alignment: .leading, spacing: 3) {
    Text("剪贴板：\(bridge.status)")
    Text("显示：\(bridge.displayStatus)")
  }.font(.caption).foregroundStyle(.secondary) }
}

/// Keep the existing SwiftUI window available for Dock/Finder reopen actions.
private struct ManagementWindowReader: NSViewRepresentable {
  var attach: (NSWindow) -> Void
  func makeNSView(context: Context) -> WindowProbe { WindowProbe(attach: attach) }
  func updateNSView(_ view: WindowProbe, context: Context) { view.attach = attach }
  final class WindowProbe: NSView {
    var attach: (NSWindow) -> Void
    init(attach: @escaping (NSWindow) -> Void) { self.attach = attach; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window { attach(window) }
    }
  }
}

/// Preserve SwiftUI's other window callbacks while turning Close into Hide.
final class ManagementWindowDelegate: NSObject, NSWindowDelegate {
  var original: NSWindowDelegate?
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.orderOut(nil)
    return false
  }
  override func responds(to selector: Selector!) -> Bool {
    super.responds(to: selector) || original?.responds(to: selector) == true
  }
  override func forwardingTarget(for selector: Selector!) -> Any? {
    if original?.responds(to: selector) == true { return original }
    return super.forwardingTarget(for: selector)
  }
}
