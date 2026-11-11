# Third-party notices / 第三方组件声明

WindowVM original sources are GPL-2.0-only (copyright 2026 WindowVM contributors). Third-party files below retain their own terms. / WindowVM 原创代码采用 GPL-2.0-only，以下第三方文件保留原许可证。

## QEMU 11.1.3

- Upstream: https://www.qemu.org/ ; source: https://download.qemu.org/qemu-11.1.3.tar.xz
- Copyright Fabrice Bellard and QEMU contributors. QEMU as a whole is GPL version 2; individual files have compatible licenses. See `LICENSES/QEMU-LICENSE` and `LICENSES/QEMU-COPYING`.
- The release bundles the Homebrew `qemu-system-aarch64` executable as `WindowVM Engine.app/Contents/MacOS/QEMU`. Its code is unchanged; the executable is re-signed with an ad-hoc hypervisor entitlement. WindowVM's separate Cocoa adapter is built from `NativeDisplay/WindowVMDisplay.m`.
- Corresponding QEMU source is provided alongside the app as the `qemu-11.1.3.tar.xz` release asset. SHA-256: `5a8289c7940dc77d3873c81a6c29ba3afe1446fc9d36e77fa1658cdbecb84b22`.
- The exact installed Homebrew build recipe is preserved in `docs/qemu-homebrew.rb`, including its source preparation, dependencies, and configure/install commands. QEMU upstream build instructions are in the source archive. Install its build dependencies with Homebrew; follow the recipe's `install` method, substituting an installation prefix and the local compiler. WindowVM's install/signing steps are in `scripts/build.sh`.
- Homebrew itself: https://github.com/Homebrew/brew (BSD-2-Clause). The copied formula is covered by `LICENSES/Homebrew-BSD-2-Clause.txt`.
- QEMU runtime libraries, `qemu-img`, `swtpm`, and QEMU share data are supplied by the user's Homebrew installation, not bundled in the app. Their licenses remain applicable to those installations.

## ARM UEFI / EDK II firmware

`Firmware/AAVMF_CODE.ms.fd` and `Firmware/AAVMF_VARS.ms.fd` are downloaded from Ubuntu's `qemu-efi-aarch64_2024.02-2ubuntu0.10_all.deb` and included in built apps. Download and checksum verification are in `scripts/setup-firmware.sh`; provenance is in `Firmware/README.md`. Full component copyright notices and license texts accompany the app in `Firmware/COPYRIGHT`. Upstream: https://github.com/tianocore/edk2 ; Ubuntu source package: https://launchpad.net/ubuntu/+source/edk2/2024.02-2ubuntu0.10 .

## VirtIO Windows ARM64 display driver

The unchanged signed files in `Guest/DisplayDriver` come from virtio-win 0.1.302, `viogpudo/w11/ARM64`. Copyright Red Hat, Google, Virtuozzo, IBM, and contributors; BSD-3-Clause. Full terms: `Guest/DisplayDriver/LICENSE.txt`. Download and source references: `Guest/DisplayDriver/README.md`.

## Artwork and screenshots / 图片

WindowVM app icon was generated for this project; see `Assets/README.md`. Screenshots show the actual WindowVM interface and a separately installed Windows guest. Windows, Microsoft Edge, and macOS names and interface elements belong to their respective owners. Screenshots are illustrative; no Windows installation or license is distributed.
