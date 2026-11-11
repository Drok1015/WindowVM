#!/bin/bash
set -euo pipefail
if [[ "$(uname -m)" != arm64 ]]; then
  echo '当前版本仅支持 Apple 芯片 Mac。' >&2
  exit 1
fi
if [[ ! -x /opt/homebrew/bin/brew ]]; then
  echo '请先安装 Apple 芯片版 Homebrew：https://brew.sh' >&2
  exit 1
fi
HOMEBREW_NO_AUTO_UPDATE=1 /opt/homebrew/bin/brew install qemu swtpm
"$(dirname "$0")/setup-firmware.sh"
