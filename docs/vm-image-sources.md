# VM Image Sources (Official)

Use official vendor sources only.

## Linux (QEMU-friendly cloud images)

Ubuntu 24.04 (Noble) cloud images:
- amd64 (current): https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
- arm64 (current): https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img
- amd64 (release snapshot): https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img
- arm64 (release snapshot): https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-arm64.img

Notes:
- `zig build tools -- vm-create-linux` defaults to the Ubuntu current cloud image URL.
- Cloud images are preferred for automated matrix hosts because cloud-init bootstrapping is deterministic.

## Windows (official Microsoft pages)

- Windows 11 download page: https://www.microsoft.com/software-download/windows11
- Windows 11 ARM64 download page: https://www.microsoft.com/software-download/windows11arm64
- Windows 11 Enterprise Evaluation: https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-enterprise

Notes:
- Microsoft may require interactive selection/sign-in before serving a direct ISO URL.
- For this repository, use these pages to obtain ISOs and then pass local ISO paths to VM scripts.

## macOS (official Apple guidance)

- macOS download guidance: https://support.apple.com/en-us/102662
- Apple Virtualization framework docs: https://developer.apple.com/documentation/virtualization
- Apple deployment/installer guidance: https://support.apple.com/guide/deployment/dep5980c3e3d/web

Notes:
- macOS virtualization is only supported on Apple hardware.
- Do not distribute prebuilt macOS images. Acquire installers/runtime assets on the target Mac host per Apple terms.

## Helper Script

List and verify links:
```bash
zig build tools -- vm-image-sources --check
```

Download Ubuntu cloud image into shared VM lab:
```bash
zig build tools -- vm-image-sources --arch amd64 --download-ubuntu --out-dir /home/a/vm_lab/images
```
