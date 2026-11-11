#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_icon="$PWD/Assets/AppIcon.png"
if [[ ! -f "$source_icon" ]]; then
  echo '缺少 Assets/AppIcon.png' >&2
  exit 1
fi
iconset="$PWD/build/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$source_icon" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  /usr/bin/sips -z "$retina_size" "$retina_size" "$source_icon" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$PWD/Assets/AppIcon.icns"
