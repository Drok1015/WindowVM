#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
package_dir="$PWD/.build/firmware-package"
package="$package_dir/qemu-efi-aarch64.deb"
checksum='fad8e80e929cd00dae8c5c8e5dd3ec85f37d9a832eea776957e5e2cf86ef2ab5'
mkdir -p "$package_dir" Firmware
if [[ ! -f "$package" ]]; then
  curl -fL --retry 3 -o "$package.part" 'https://archive.ubuntu.com/ubuntu/pool/main/e/edk2/qemu-efi-aarch64_2024.02-2ubuntu0.10_all.deb'
  mv "$package.part" "$package"
fi
actual="$(shasum -a 256 "$package" | cut -d ' ' -f 1)"
if [[ "$actual" != "$checksum" ]]; then
  echo 'UEFI 软件包 SHA-256 校验失败，请检查 .build/firmware-package/qemu-efi-aarch64.deb。' >&2
  exit 1
fi
mkdir -p "$package_dir/archive" "$package_dir/extracted"
tar -xf "$package" -C "$package_dir/archive"
for payload in "$package_dir"/archive/data.tar.*; do
  tar -xf "$payload" -C "$package_dir/extracted"
done
cp -L "$package_dir/extracted/usr/share/AAVMF/AAVMF_CODE.ms.fd" Firmware/AAVMF_CODE.ms.fd
cp -L "$package_dir/extracted/usr/share/AAVMF/AAVMF_VARS.ms.fd" Firmware/AAVMF_VARS.ms.fd
cp "$package_dir/extracted/usr/share/doc/qemu-efi-aarch64/copyright" Firmware/COPYRIGHT
echo 'Secure Boot UEFI 固件已就绪。'
