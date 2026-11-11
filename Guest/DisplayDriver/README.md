# Windows ARM64 VirtIO GPU driver

Source: official virtio-win 0.1.302 release ISO:
https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso

Extracted unchanged from `viogpudo/w11/ARM64`. `viogpudo.cat` carries the Microsoft Windows Hardware Compatibility Publisher signature. License: accompanying LICENSE.txt (BSD-3-Clause). Source: https://github.com/virtio-win/kvm-guest-drivers-windows/tree/master/viogpu

InstallDisplay.cmd stages the signed INF using Windows pnputil. The normal-user WindowVM agent targets the VirtIO adapter directly with D3DKMTEscape and SetDisplayConfig, then verifies the actual mode through Win32. The viogpures.exe/viogpuap.exe/vgpusrv.exe files are unchanged upstream companion binaries; WindowVM does not run them or install their service. Secure Boot remains enabled.
