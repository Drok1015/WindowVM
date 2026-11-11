#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/display-tests
clang -fobjc-arc -DWINDOWVM_DISPLAY_TEST -framework AppKit -framework QuartzCore -mmacosx-version-min=14.0 NativeDisplay/WindowVMDisplay.m NativeDisplay/DisplayTests.m -o .build/display-tests/run
.build/display-tests/run
