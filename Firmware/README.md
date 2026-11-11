# ARM64 Secure Boot UEFI

通过 `scripts/setup-firmware.sh` 下载、校验并解包 Ubuntu 的 qemu-efi-aarch64 软件包。只使用 `AAVMF_CODE.ms.fd` 与预注册微软证书的 `AAVMF_VARS.ms.fd`，不使用 snakeoil 测试密钥。

软件包：`qemu-efi-aarch64_2024.02-2ubuntu0.10_all.deb`

SHA-256：`fad8e80e929cd00dae8c5c8e5dd3ec85f37d9a832eea776957e5e2cf86ef2ab5`

来源与校验值：[Ubuntu 软件包页面](https://packages.ubuntu.com/noble-updates/all/qemu-efi-aarch64/download)。上游许可证保存在 `COPYRIGHT`。

FD 二进制不纳入 Git；构建时复制到应用资源目录。每台新虚拟机必须从变量模板创建独立可写副本。不能在已有系统上随意替换 UEFI 变量文件，尤其是启用 BitLocker 的系统。
