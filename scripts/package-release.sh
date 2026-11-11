#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=0.1.0
qemu_version=11.1.3
qemu_sha=5a8289c7940dc77d3873c81a6c29ba3afe1446fc9d36e77fa1658cdbecb84b22
if [[ $(/opt/homebrew/bin/qemu-system-aarch64 --version | head -1) != "QEMU emulator version $qemu_version"* ]]; then
  echo "This release requires QEMU $qemu_version; update the source/recipe/notices before changing engines." >&2
  exit 1
fi
if [[ ${1:-} != --skip-build ]]; then ./scripts/build.sh; fi
out="$PWD/build/release"
mkdir -p "$out"
source_archive="$PWD/.build/qemu-$qemu_version.tar.xz"
if [[ ! -f "$source_archive" ]]; then
  curl -fL --retry 3 -o "$source_archive.part" "https://download.qemu.org/qemu-$qemu_version.tar.xz"
  mv "$source_archive.part" "$source_archive"
fi
[[ $(shasum -a 256 "$source_archive" | awk '{print $1}') == "$qemu_sha" ]] || { echo 'QEMU source checksum mismatch' >&2; exit 1; }
cp "$source_archive" "$out/"
stage=$(mktemp -d "$PWD/build/release-stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
/usr/bin/ditto build/WindowVM.app "$stage/WindowVM.app"
ln -s /Applications "$stage/Applications"
cp docs/INSTALL.txt "$stage/INSTALL.txt"
cp LICENSE THIRD_PARTY_NOTICES.md "$stage/"
cp -R LICENSES "$stage/"
cp docs/qemu-homebrew.rb "$stage/"
codesign --verify --deep --strict --verbose=2 "$stage/WindowVM.app"
# Do not package VM disks, user configuration, clipboard tokens, or Windows media.
/usr/bin/hdiutil create -ov -volname "WindowVM $version" -srcfolder "$stage" -format UDZO "$out/WindowVM-$version-macos-arm64.dmg"
(cd "$out" && shasum -a 256 "WindowVM-$version-macos-arm64.dmg" "qemu-$qemu_version.tar.xz" > SHA256SUMS.txt)
echo "$out"
