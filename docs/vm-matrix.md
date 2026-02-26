# VM Matrix Workflow (Shared Across Projects)

This project supports a shared VM lab rooted at `VM_LAB_DIR` (default: `/home/a/vm_lab`) so the same VM hosts can be reused by multiple repositories.

## Prerequisites
- `qemu-system-x86_64`
- `qemu-img`
- `ssh`
- `rsync`
- `curl`
- `ssh-keygen`

Check locally:
```bash
zig build tools -- vm-check-prereqs
```

Official VM image source links:
```bash
zig build tools -- vm-image-sources --check
```
See `/home/a/projects/zig/browser_driver/docs/vm-image-sources.md` for the curated source list.

## 1) Initialize Shared VM Lab
```bash
zig build tools -- vm-init-lab --project browser_driver
```

This creates:
- `/home/a/vm_lab/images`
- `/home/a/vm_lab/projects/browser_driver`
- `/home/a/vm_lab/hosts`

## 2) Linux VM (QEMU) for Matrix Runs
Create VM assets:
```bash
zig build tools -- vm-create-linux --project browser_driver --name linux-matrix
```

Override the Linux base image URL (and optional SHA256):
```bash
zig build tools -- vm-create-linux \
  --project browser_driver \
  --name linux-matrix \
  --base-url "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img" \
  --base-sha256 "<sha256>"
```

Start the VM in a dedicated terminal:
```bash
zig build tools -- vm-start-linux --project browser_driver --name linux-matrix
```

Run matrix remotely in VM and collect artifacts back:
```bash
zig build tools -- vm-run-linux-matrix --project browser_driver --name linux-matrix
```

## 3) Register macOS/Windows Hosts
Register any reachable host (physical machine or separate VM):
```bash
zig build tools -- vm-register-host --name macos-host --os macos --arch arm64 --address user@mac.example
zig build tools -- vm-register-host --name windows-host --os windows --arch x64 --address user@win.example
```

Run matrix on a registered host:
```bash
zig build tools -- vm-run-remote-matrix --project browser_driver --host macos-host
zig build tools -- vm-run-remote-matrix --project browser_driver --host windows-host
```

## 4) Signed Evidence and GA Bundle
If signatures are required, set:
- `MATRIX_GPG_KEY_ID` before matrix runs
- `RELEASE_GPG_KEY_ID` before bundle creation

Collect Linux/macOS/Windows evidence and build final bundle:
```bash
zig build tools -- vm-ga-collect-and-bundle \
  --project browser_driver \
  --release-id v1-ga \
  --linux-host linux-matrix \
  --macos-host macos-host \
  --windows-host windows-host
```

## Notes
- `zig build` supports QEMU-assisted foreign execution with `-fqemu` for cross-arch binaries on Linux hosts.
- Full browser parity still depends on installed browsers/drivers in each target host/VM.
- Mobile webview bridge smoke requires host toolchains (`adb` or `shizuku` for Android, `ios_webkit_debug_proxy` or `tidevice` for iOS) on the relevant matrix host.
