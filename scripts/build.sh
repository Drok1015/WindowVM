#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
./scripts/build-icon.sh
if [[ ! -f Firmware/AAVMF_CODE.ms.fd || ! -f Firmware/AAVMF_VARS.ms.fd ]]; then
  echo '缺少安全启动固件，请先运行 scripts/setup-firmware.sh。' >&2
  exit 1
fi
app="$PWD/build/WindowVM.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/WindowVM "$app/Contents/MacOS/WindowVM"
# Replace resources only; virtual machine data lives separately in Application Support.
rm -rf "$app/Contents/Resources/Guest"
cp -R Guest "$app/Contents/Resources/Guest"
cp docs/README.html "$app/Contents/Resources/README.html"
cp Assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
cp -R LICENSES "$app/Contents/Resources/"
cp docs/qemu-homebrew.rb "$app/Contents/Resources/"
# The UI supports macOS 14, but the installed QEMU may require a newer OS.
qemu_min=$(/usr/bin/otool -l /opt/homebrew/bin/qemu-system-aarch64 | awk '/minos / {print $2; exit}')
minimum_macos=$(python3 -c 'import sys; print(max(["14.0", sys.argv[1]], key=lambda v: tuple(map(int, v.split(".")))))' "$qemu_min")
mkdir -p "$app/Contents/Resources/Firmware"
cp Firmware/AAVMF_CODE.ms.fd Firmware/AAVMF_VARS.ms.fd Firmware/COPYRIGHT "$app/Contents/Resources/Firmware/"
engine="$app/Contents/Helpers/WindowVM Engine.app"
mkdir -p "$engine/Contents/MacOS" "$engine/Contents/Resources"
install -m 755 /opt/homebrew/bin/qemu-system-aarch64 "$engine/Contents/MacOS/QEMU"
clang -fobjc-arc -framework AppKit -mmacosx-version-min=14.0 NativeDisplay/EngineLauncher.m -o "$engine/Contents/MacOS/WindowVMEngine"
cp Assets/AppIcon.icns "$engine/Contents/Resources/AppIcon.icns"
cat > "$engine/Contents/Info.plist" <<'ENGINE'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WindowVMEngine</string>
<key>CFBundleIdentifier</key><string>local.windowvm.engine</string>
<key>CFBundleName</key><string>WindowVM Engine</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
ENGINE
clang -fobjc-arc -dynamiclib -framework AppKit -framework QuartzCore -mmacosx-version-min=14.0 NativeDisplay/WindowVMDisplay.m -o "$engine/Contents/Resources/WindowVMDisplay.dylib"
codesign --force --sign - "$engine/Contents/Resources/WindowVMDisplay.dylib"
codesign --force --sign - --entitlements scripts/hypervisor.entitlements "$engine/Contents/MacOS/QEMU"
/usr/bin/plutil -insert LSMinimumSystemVersion -string "$minimum_macos" "$engine/Contents/Info.plist"
codesign --force --sign - --entitlements scripts/hypervisor.entitlements "$engine"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WindowVM</string>
<key>CFBundleIdentifier</key><string>local.windowvm.desktop</string>
<key>CFBundleName</key><string>WindowVM</string>
<key>CFBundleDisplayName</key><string>WindowVM</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/plutil -replace LSMinimumSystemVersion -string "$minimum_macos" "$app/Contents/Info.plist"
codesign --force --sign - "$app"
touch "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$engine"
echo "$app"
