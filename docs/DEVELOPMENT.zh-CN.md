> 开发记录（2026-11-10）。当前下载、系统要求与发布状态以根目录 [README](../README.md) 为准。

# WindowVM

Apple 芯片 Mac 上的 Windows 11 ARM 虚拟机原型。SwiftUI 管理界面 + Homebrew QEMU/HVF + swtpm。目标是浏览网页、宿主网络互通和双向文字剪贴板。

## 启动

```sh
./scripts/setup.sh
./scripts/build.sh
open build/WindowVM.app
```

在应用内打开微软官方下载入口，下载 ARM64 ISO 后选择安装镜像。详细步骤见 [安装说明](README.html)。应用不包含 Windows 镜像或许可证，不接触 Parallels 数据。

当前支持 Apple 芯片、macOS 14 及以上、位于 `/opt/homebrew` 的 Homebrew。开发环境为 macOS 27.2、Swift 6.4.2、QEMU 11.1.3、swtpm 0.10.2。程序并非独立分发包，运行仍依赖本机 Homebrew 库。

## 已实现

- 单台 Windows ARM 虚拟机：4 核 / 8 GB / 80 GB 稀疏磁盘默认值，可在首次创建前配置。
- 带微软证书的 Secure Boot ARM UEFI、NVMe、USB 键鼠、VirtIO GPU 显示与固件回退 framebuffer、TPM 2.0。
- 窗口可从边角自由缩放；Windows 实际分辨率按 800ms 节流适配，拖动结束补齐最后尺寸，范围 640×480 至 3840×2160。需安装随附的 ARM64 显示驱动与配套程序。
- 显示进程封装为有独立应用标识的 WindowVM Engine.app，使用同一套应用图标，保留硬件虚拟化签名权限。
- NAT 联网，Windows 通过 `10.0.2.2` 访问宿主；一组仅绑定 `127.0.0.1` 的 TCP 端口转发。
- 自有 Windows PowerShell STA 剪贴板配套程序，启动目录登录自启，无管理员权限。仅同步纯文本，最大 512 KiB。
- 剪贴板桥接仅监听 IPv4 本机地址，随机令牌鉴权、请求限额、连接超时、版本冲突拒绝；仅虚拟机运行时提供服务；关闭剪贴板后仍保留显示适配端点。
- 关闭 Engine 窗口或退出 Engine 时保存内存和设备状态并退出进程；再次打开 WindowVM 或 Engine 时自动继续。管理界面也提供“保存并暂停”和“继续 Windows”。
- QMP 正常关机请求、强制停止确认、运行日志、文件锁与残留 QEMU PID 检查。
- 数据独立保存在 `~/Library/Application Support/WindowVM/Windows11`。

## 验证

```sh
swift test
./scripts/test-display.sh
./scripts/build.sh
python3 scripts/smoke.py
python3 scripts/smoke-suspend.py
```

测试覆盖配置限制、中文剪贴板、真实 HTTP 鉴权与版本冲突。冒烟测试使用生产参数构造器，在独立临时目录创建空磁盘和工具 ISO，实际启动 HVF、UEFI、TPM、NVMe、NAT 转发监听器，通过 QMP 检查运行状态、获取 framebuffer 截图并发送关机请求；最后退出测试虚拟机，清理临时数据。截图写入 `build/firmware-smoke.png`。

2026-11-10 已完成真实 Windows 11 ARM64 安装、账号设置、正常关机和再次启动验证。浏览器外部 HTTPS 页面、Windows 访问 Mac 本机 HTTP 页面、Mac 通过 `127.0.0.1:18080` 访问 Windows TCP 8080 均已实测通过。双向中文与 emoji 复制粘贴通过；重新登录后剪贴板配套程序自动连接。详见 [实机验证记录](verification-2026-11-10.txt)。

2026-11-10 自适应窗口已完成冷启动验证：登录后配套程序自动连接，右下角拖动令实际分辨率从 1280×800 变为 1200×724；连续拖动的 800ms 节流与最终尺寸补齐通过 AppKit 事件模式测试。详见 [显示验证记录](verification-display-2026-11-10.txt)。

本机 Windows 已按用户授权保留 `WindowVM-Host-TCP8080` 入站规则，仅允许宿主地址 `10.0.2.2` 访问 TCP 8080，禁止边缘遍历。既有 PowerShell 阻止规则保留；测试使用独立临时程序，响应一次请求后退出并移入回收站。该规则不随修改应用端口自动更新，其他 Windows 服务端口需另行配置防火墙。

## 宿主系统代理

虚拟机不会自动继承 macOS 代理。打开 Windows 的 `WINDOWVM_TOOLS` 光盘运行 `UseHostProxy.cmd`，会先测试 HTTPS，再将本次启动读取的 Mac HTTP/HTTPS 系统代理写入当前 Windows 用户配置。Mac 的 `127.0.0.1` / `localhost` 代理映射为 `10.0.2.2`，无需开放局域网监听。支持系统代理的浏览器和应用会使用它；自行管理代理或使用 WinHTTP 的程序需另行设置。

`RestoreProxy.cmd` 可恢复首次修改前的 Windows 代理。Mac 代理端口更改后，正常重启虚拟机并再次运行 `UseHostProxy.cmd`；当前不自动转换 PAC 脚本或仅 SOCKS 配置。

## 暂停与继续

关闭 Engine 窗口、退出 Engine 或退出运行中的 WindowVM，会保存 Windows 内存及设备状态，完成后释放虚拟机进程和内存。下次打开 WindowVM 或 Engine 自动恢复到原来的操作；管理界面的“继续 Windows”也可恢复。真正关机仍使用 Windows 开始菜单或“正常关机”。暂停不是可反复回滚的历史快照，只保存一次待继续的状态。

保存期间请等待窗口自行消失，不要强制退出。保存文件可能占用接近所配置内存的磁盘空间。暂停期间禁止修改 CPU、内存和挂载镜像；恢复使用原工具光盘。引擎、固件、磁盘或 TPM 文件不匹配时会保留文件并报告错误，不会偷偷冷启动。升级 QEMU / swtpm 或迁移路径前应先继续并正常关机。网络旧连接可能需要刷新或重新连接。

实现基于 [QEMU 文件迁移](https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html#command-migrate)；[TPM 模拟器支持保存和恢复](https://www.qemu.org/docs/master/specs/tpm.html#migration-with-the-tpm-emulator)。完整保存确认后才退出引擎；恢复开始执行前登记一次性消费状态，防止崩溃后重复载入旧内存与新磁盘。

## 已知边界

- 不支持 x86 系统、3D 加速、音频、共享文件夹、桥接、多版本快照管理、多虚拟机管理。
- 网卡需要 VirtIO ISO 内的 ARM64 NetKVM 驱动，应用提供上游下载链接。
- 当前 Homebrew QEMU 的 TPM PPI 内存区在本机 HVF 下触发 `HV_BAD_ARGUMENT`，显式设置 `ppi=off` 后启动通过。TPM 2.0 仍提供服务，Windows 可能记录 Physical Presence 接口相关事件；Windows 安装兼容性需继续验证。
- Homebrew 自带 ARM 固件在真实 Windows 11 安装检查中被判定不支持安全启动。现改用 Ubuntu AAVMF 安全启动固件和预注册微软证书的变量模板，见 [固件来源](../Firmware/README.md)。现有虚拟机迁移必须关机并保留原固件变量备份，不自动清除已有变量或绕过 Windows 要求。
- 网络仅为 NAT/TCP 转发；VPN、代理、企业内网环境需要实测。
- 必须关机后整体备份虚拟机目录，包含固件变量与 TPM 状态；强制停止可能造成数据丢失。暂停文件与当前磁盘是一组，不要在暂停期间修改或单独恢复磁盘、TPM、UEFI、工具光盘。
- 应用使用本机 ad-hoc 签名，尚未做开发者签名、公证和安装包分发。若重新分发 QEMU，需要遵循其 GPL 及各依赖许可证要求。

显示适配通过针对 QEMU 11.1.3 的 Cocoa 适配库实现；升级 QEMU 后需重新验证私有视图接口。窗口尺寸按 macOS backing scale 映射 Windows 物理像素：Retina 2× 屏幕上 1280×800 的窗口渲染为 2560×1600。Windows 显示缩放设为 200% 可保持文字大小；普通 1× 屏幕可用 100%。

## 代码

- `Sources/VMCore`：配置校验、QEMU 参数、剪贴板版本状态。
- `Sources/WindowVM`：SwiftUI、进程生命周期、QMP 控制、本机剪贴板 HTTP 服务。
- `Guest`：Windows 配套程序与安装入口。
- `Sources/VMSmoke`、`scripts/smoke.py`：真实虚拟机启动验证。

上游资料：[QEMU](https://www.qemu.org/docs/master/system/introduction.html)、[微软 ARM64 ISO](https://www.microsoft.com/zh-cn/software-download/windows11arm64)、[VirtIO Windows 驱动](https://github.com/virtio-win/virtio-win-pkg-scripts)。
