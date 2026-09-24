# jev-vphone-cli

Virtual iPhone boot tool using Apple's Virtualization.framework with PCC research VMs, with a Jev-driven agent loop for natural-language phone control.

## Quick Reference

- **Build:** `make build`
- **Boot (GUI):** `make boot`
- **Boot (DFU):** `make boot_dfu`
- **Taking over this work?** Read [`docs/handoff.md`](docs/handoff.md) first — state, traps, and what is blocked.
- **Jev control:** `make jev PROMPT="turn on airplane mode"` (needs `TYPESAFE_API_KEY`)
- **Jev, Simulator:** `make setup_jev`, then `make jev SIM=booted PROMPT="turn on Bold Text"` (semantic accessibility + native HID; no OCR)
- **Jev, no VM:** `make jev_fake PROMPT="..."` — runs against `tests/jev_fake_phone.py`
- **All targets:** `make help`
- **Python venv:** `make setup_venv` (installs to `.venv/`, activate with `source .venv/bin/activate`)
- **Platform:** macOS 15+ (Sequoia), SIP/AMFI disabled
- **Language:** Swift 6.0 (SwiftPM), private APIs via [Dynamic](https://github.com/mhdhejazi/Dynamic)
- **Python deps:** `capstone`, `keystone-engine`, `pyimg4` (see `requirements.txt`)

## Workflow Rules

- Do not create, read, or update `/TODO.md`.
- Ignore `/TODO.md` if it exists locally; it is intentionally not part of the repo workflow anymore.
- Track plan, progress, assumptions, blockers, and next actions in commit history, code comments when warranted, and current research docs instead of a repo TODO file.

For any changes applying new patches, also update research/0_binary_patch_comparison.md. Dont forget this.

## Local Skills

- If working on kernel analysis, symbolication lookups, or kernel patch reasoning, read `skills/kernel-analysis-vphone600/SKILL.md` first.
- Use this skill as the default procedure for `vphone600` kernel work.

## Firmware Variants

| Variant          | Boot Chain     |    CFW    | Make Targets                       |
| ---------------- | :------------: | :-------: | ---------------------------------- |
| **Regular**      | 52 patches     | 10 phases | `fw_patch` + `cfw_install`         |
| **Development**  | 66 patches     | 12 phases | `fw_patch_dev` + `cfw_install_dev` |
| **Jailbreak**    | 127 patches    | 14 phases | `fw_patch_jb` + `cfw_install_jb`   |
| **Experimental** | 141 patches    | 18 phases | `fw_patch_exp` + `cfw_install_exp` |

> JB finalization (symlinks, Sileo, apt, TrollStore) runs automatically on first boot via `/cores/vphone_jb_setup.sh` LaunchDaemon. Monitor progress: `/var/log/vphone_jb_setup.log`.

> EXP is a JB superset that patches the kernel and DSC to make some Apple services think the device is not a VM, while keeping VM-specific services (graphics passthrough, compute/accel fast paths) working correctly. Other variants are deliberately NOT affected by these changes.

See `research/` for detailed firmware pipeline, component origins, patch breakdowns, and boot flow documentation.

## Architecture

```
Makefile                          # Single entry point — run `make help`

sources/
├── vphone.entitlements               # Private API entitlements (5 keys)
└── vphone-cli/                       # Swift 6.0 executable (pure Swift, no ObjC)
    ├── main.swift                    # Entry point — NSApplication + AppDelegate
    ├── VPhoneAppDelegate.swift       # App lifecycle, SIGINT, VM start/stop
    ├── VPhoneCLI.swift               # ArgumentParser options (no execution logic)
    ├── VPhoneBuildInfo.swift         # Auto-generated build-time commit hash
    │
    │   # VM core
    ├── VPhoneVirtualMachine.swift    # @MainActor VM configuration and lifecycle
    ├── VPhoneHardwareModel.swift     # PV=3 hardware model via Dynamic
    ├── VPhoneVirtualMachineView.swift # Touch-enabled VZVirtualMachineView + helpers
    ├── VPhoneError.swift             # Error types
    │
    │   # Guest daemon client (vsock)
    ├── VPhoneControl.swift           # Host-side vsock client for vphoned (length-prefixed JSON)
    │
    │   # Jev agent — natural-language phone control
    ├── VPhoneJevClient.swift         # TypeSafe System One HTTP client + question/answer types
    ├── VPhoneJevObserver.swift       # JevObservation + accessibility / Vision-OCR providers
    ├── VPhoneJevQuestions.swift      # Question construction, action vocabulary, text spans
    ├── VPhoneJevAgent.swift          # observe→decide→act loop; all thresholds live here
    ├── VPhoneJevSocket.swift         # Out-of-process observer/actuator over vphone.sock
    ├── VPhoneJevCLI.swift            # `vphone-cli jev "<goal>"`
    │
    │   # Window & UI
    ├── VPhoneWindowController.swift  # @MainActor VM window management + toolbar
    ├── VPhoneKeyHelper.swift         # Keyboard/hardware key event dispatch to VM
    ├── VPhoneLocationProvider.swift  # CoreLocation → guest forwarding over vsock
    ├── VPhoneScreenRecorder.swift    # VM screen recording to file
    │
    │   # Menu bar (extensions on VPhoneMenuController)
    ├── VPhoneMenuController.swift    # Menu bar controller
    ├── VPhoneMenuKeys.swift          # Keys menu — home, power, volume, spotlight
    ├── VPhoneMenuType.swift          # Type menu — paste ASCII text to guest
    ├── VPhoneMenuLocation.swift      # Location menu — host location sync toggle
    ├── VPhoneMenuConnect.swift       # Connect menu — devmode, ping, version, file browser
    ├── VPhoneMenuInstall.swift       # Install menu — IPA installation to guest
    ├── VPhoneMenuRecord.swift        # Record menu — screen recording controls
    ├── VPhoneMenuBattery.swift       # Battery menu — battery status display
    │
    │   # IPA installation
    ├── VPhoneIPAInstaller.swift      # IPA extraction, signing, and installation
    ├── VPhoneSigner.swift            # Mach-O binary signing utilities
    │
    │   # File browser (SwiftUI)
    ├── VPhoneFileWindowController.swift # File browser window (NSHostingController)
    ├── VPhoneFileBrowserView.swift   # SwiftUI file browser with search + drag-drop
    ├── VPhoneFileBrowserModel.swift  # @Observable file browser state + transfers
    └── VPhoneRemoteFile.swift        # Remote file data model

scripts/
├── vphoned/                      # Guest daemon (ObjC, runs inside iOS VM over vsock)
├── patchers/                     # Python CFW patcher modules
│   └── cfw.py                    #   CFW binary patcher entrypoint
├── resources/                    # Resource archives (git submodule)
├── repos/                        # Toolchain source repos (git submodules: trustcache, insert_dylib, libimobiledevice stack)
├── patches/                      # Build-time patches (libirecovery)
├── fw_prepare.sh                 # Download IPSWs, merge cloudOS into iPhone
├── fw_manifest.py                # Generate hybrid BuildManifest/Restore plists
├── cfw_install.sh                # Install CFW (regular)
├── cfw_install_dev.sh            # Regular + rpcserver daemon
├── cfw_install_jb.sh             # Regular + jetsam fix + procursus
├── cfw_install_exp.sh            # JB + experimental research patches (hv_vmm rename, DT identity)
├── cfw_install_host.sh           # Host-mount CFW driver (attaches Disk.img, VM off; re-execs sudo)
├── vm_create.sh                  # Create VM directory
├── setup_machine.sh              # Full automation (setup → first boot)
├── setup_tools.sh                # Install deps, build toolchain from submodules, create venv
├── setup_venv.sh                 # Create Python venv
├── setup_venv_linux.sh           # Create Python venv (Linux)
├── setup_libimobiledevice.sh     # Build libimobiledevice stack from scripts/repos submodules
└── tail_jb_patch_logs.sh         # Tail JB patch log output

tools/
└── apfs_snap_rename.py           # Offline APFS boot-snapshot flip (used by cfw_install_host.sh)

research/                         # Detailed firmware/patch documentation
```

### Key Patterns

- **Private API access:** Via [Dynamic](https://github.com/mhdhejazi/Dynamic) library (runtime method dispatch from pure Swift). No ObjC bridge.
- **App lifecycle:** `main.swift` → `NSApplication` + `VPhoneAppDelegate`. CLI args parsed before run loop. AppDelegate drives VM start/window/shutdown.
- **Configuration:** `ArgumentParser` → `VPhoneVirtualMachine.Options` → `VZVirtualMachineConfiguration`.
- **Guest daemon (vphoned):** ObjC daemon inside iOS VM, vsock port 1337, length-prefixed JSON protocol. Host side is `VPhoneControl` with auto-reconnect.
- **Menu system:** `VPhoneMenuController` + per-menu extensions (Keys, Type, Location, Connect, Install, Record).
- **File browser:** SwiftUI (`VPhoneFileBrowserView` + `VPhoneFileBrowserModel`) in `NSHostingController`. Search, sort, upload/download, drag-drop via `VPhoneControl`.
- **IPA installation:** `VPhoneIPAInstaller` extracts + re-signs via `VPhoneSigner` + installs over vsock.
- **Screen recording:** `VPhoneScreenRecorder` captures VM display. Controls via Record menu.
- **Jev agent:** Natural-language goal → `JevObservation` (text) → one batched TypeSafe
  request → code-side gating → one bounded action. Jev returns typed judgments only: it
  never generates text, never produces coordinates, and never decides whether to act —
  every threshold lives in `VPhoneJevAgent.Policy`. See `docs/jev.md`.
- **Screen→text:** Jev reads semantic accessibility elements as text. The Simulator
  uses AXe's direct accessibility bridge and native HID; the VM uses the guest tree.
  Jev refuses an unavailable tree rather than falling back to OCR. Both fill
  the same observation struct —
  see `research/jev_accessibility_spike.md`.

---

## Coding Conventions

### Swift

- **Language:** Swift 6.0 (strict concurrency).
- **Style:** Pragmatic, minimal. No unnecessary abstractions.
- **Sections:** Use `// MARK: -` to organize code within files.
- **Access control:** Default (internal). Only mark `private` when needed for clarity.
- **Concurrency:** `@MainActor` for VM and UI classes. `nonisolated` delegate methods use `MainActor.isolated {}` to hop back safely.
- **Naming:** Types are `VPhone`-prefixed. Match Apple framework conventions.
- **Private APIs:** Use `Dynamic()` for runtime method dispatch. Touch objects use `NSClassFromString` + KVC to avoid designated initializer crashes.
- **NSWindow `isReleasedWhenClosed`:** Always set `window.isReleasedWhenClosed = false` for programmatically created windows managed by an `NSWindowController`. The default `true` causes `objc_release` crashes on dangling pointers during CA transaction commit.

### Shell Scripts

- Use `zsh` with `set -euo pipefail`.
- Scripts resolve their own directory via `${0:a:h}` or `$(cd "$(dirname "$0")" && pwd)`.

### Python Scripts

### Kernel patcher guardrails

- For kernel patchers, never hardcode file offsets, virtual addresses, or preassembled instruction bytes inside patch logic.
- All instruction matching must be derived from Capstone decode results (mnemonic / operands / control-flow), not exact operand-string text when a semantic operand check is possible.
- All replacement instruction bytes must come from Keystone-backed helpers already used by the project (for example `asm(...)`, `NOP`, `MOV_W0_0`, etc.).
- Prefer source-backed semantic anchors: in-image symbol lookup, string xrefs, local call-flow, and XNU correlation. Do not depend on repo-exported per-kernel symbol dumps at runtime.
- When retargeting a patch, write the reveal procedure and validation steps into the relevant research doc or commit notes before handing off for testing. Do not create `TODO.md`.
- For `patch_bsd_init_auth` specifically, the allowed reveal flow is: recover `bsd_init` -> locate rootvp panic block -> find the unique in-function `call` -> `cbnz w0/x0, panic` -> `bl imageboot_needed` site -> patch the branch gate only.

- Patchers use `capstone` (disassembly), `keystone-engine` (assembly), `pyimg4` (IM4P handling).
- Dynamic pattern finding (string anchors, ADRP+ADD xrefs, BL frequency) — no hardcoded offsets.
- Each patch logged with offset and before/after state.
- Use project venv (`source .venv/bin/activate`). Create with `make setup_venv`.

## Build & Sign

The binary requires private entitlements for PV=3 virtualization. Always use `make build` — never `swift build` alone, as the unsigned binary will fail at runtime.

## Design System

- **Audience:** Security researchers. Terminal-adjacent workflow.
- **Feel:** Research instrument — precise, informative, no decoration.
- **Palette:** Dark neutral (`#1a1a1a` bg), status green/amber/red/blue accents.
- **Typography:** System monospace (SF Mono / Menlo) for UI and log output.
- **Depth:** Flat with 1px borders (`#333333`). No shadows.
- **Spacing:** 8px base unit, 12px component padding, 16px section gaps.
