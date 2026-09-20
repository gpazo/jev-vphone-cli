# Accessibility tree spike — turning the screen into text

## Why this exists

Jev takes **text only**. TypeSafe's docs are explicit: *"Jev accepts text only.
State must be a string, JSON object, or array of text values. Images, audio, and
video are not supported (yet)."*

The phone's control surface is visual. `VPhoneHostControl` returns a base64
grayscale JPEG with every command, and nothing else describes what is on screen.
So something has to turn pixels into text before Jev can reason about a phone at
all.

Two candidates:

| | Sees | Cost | Status |
|---|---|---|---|
| **Accessibility tree** (guest) | roles, labels, values, frames, icon-only controls, toggle state, offscreen elements | one vsock round trip | this document |
| **Vision OCR** (host) | rendered text only | ~100ms, local, free | working fallback in `VPhoneJevObserver.swift` |

OCR is the fallback and it genuinely works for text-heavy UI. What it cannot do
is see a button with no text, or tell you whether a switch is on. That is the
whole reason to pursue the tree.

## What was already there

The plumbing was built end-to-end and then abandoned one file short:

| Piece | Location | State |
|---|---|---|
| Host client | `VPhoneControl.accessibilityTree(pid:depth:)` | existed |
| Wire dispatch | `vphoned.m:441` | existed |
| Guest handler | `vphoned_accessibility.m` | **21-line stub returning an error** |

The stub's TODO listed four approaches: XPC to `com.apple.accessibility.AXRuntime`,
`AXUIElement`, SpringBoard dylib injection, and `UIAccessibility` via
`task_for_pid`. There was no research doc behind it — the only "accessibility"
mentions anywhere in `research/` are unrelated (CheckerBoard, Camera).

## Why in-process before injection

The stub ranks injection highly. The entitlements argue otherwise.

`scripts/vphoned/entitlements.plist` — inherited wholesale from TrollVNC, as the
leftover `keychain-access-groups: com.82flex.TrollVNCApp` shows — already grants:

- `platform-application` — the gate for most private API use
- `com.apple.private.security.storage.universalaccess` — accessibility storage
- `com.apple.springboard.debugapplications` — the debug/injection entitlement
- `com.apple.QuartzCore.global-capture` / `.secure-capture` / `.system-layers`
- `user-preference-read` / `user-preference-write`

vphoned runs as a **root LaunchDaemon** (`RunAtLoad` + `KeepAlive`) and already
dlopens private frameworks — `vp_apps_load()` in `vphoned_apps.m` is the pattern.

A root platform-application with the universal-access entitlement should be able
to ask the accessibility runtime directly. Injection is a fallback for when it
cannot, not the opening move.

## Procedure

### 1. Recon — do this first

```sh
make jev_probe                      # or: printf '{"t":"ax_probe"}\n' | nc -U vm/vphone.sock
```

Reports, per candidate library: whether the file exists, whether `dlopen`
succeeded, and which symbols resolved. Also which Objective-C classes are
registered, and whether the accessibility server currently reports itself
enabled.

Candidates probed (`vphoned_accessibility.m`):

```
/usr/lib/libAccessibility.dylib
/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities
/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime
/System/Library/PrivateFrameworks/AccessibilitySharedSupport.framework/AccessibilitySharedSupport
```

Server-gate symbols: `_AXSApplicationAccessibilityEnabled`,
`_AXSSetApplicationAccessibilityEnabled`, `_AXSAutomationEnabled`,
`_AXSSetAutomationEnabled`.

Element-API symbols: `AXUIElementCreateApplication`,
`AXUIElementCopyAttributeValue`, `AXUIElementCopyMultipleAttributeValues`,
`AXUIElementGetPid`, `AXUIElementCopyElementAtPosition`.

**Record the probe output in this file.** It decides everything downstream, and a
negative result is as useful as a positive one.

### 2. Turn the server on

Elements stay empty while the accessibility server is off, and it is off by
default. This is the step most likely to be mistaken for "the API doesn't work".

```
{"t":"accessibility_tree","action":"enable"}
```

`JevAccessibilityProvider` attempts this once per host process before its first
observation, so in normal operation it is automatic.

### 3. Walk the tree

```
{"t":"accessibility_tree","pid":<frontmost>,"depth":-1}
```

The pid comes from `appForeground()`. Attribute names differ between iOS and
macOS and across firmwares, so each field tries several and takes the first that
answers — see `vp_attribute_candidates()`:

| Field | Tried, in order |
|---|---|
| label | `AXLabel`, `AXTitle`, `AXDescription`, `AXName` |
| value | `AXValue`, `AXValueDescription` |
| role | `AXRole`, `AXTraits`, `AXSubrole` |
| frame | `AXFrame`, `AXPosition`, `AXSize` |
| children | `AXChildren`, `AXVisibleChildren` |

**These names are hypotheses, not confirmed facts.** Narrow them once the probe
says what this firmware actually answers to.

### 4. If the element API is absent

In rough order of expected effort:

1. **Missing entitlement.** You control `signcert.p12` and `entitlements.plist`,
   and AMFI is disabled in the guest — adding e.g. a
   `com.apple.private.accessibility.*` key costs a rebuild, not a research cycle.
   Try this before anything structural.
2. **Objective-C surface instead of C.** If the probe finds `AXElement` or
   `AXBackBoardServer` but no `AXUIElement*` functions, the runtime is reachable
   through classes rather than the C API. Rework the walk around them.
3. **SpringBoard dylib injection.** `insert_dylib` is already a submodule under
   `scripts/repos/`, the JB variant ships LaunchDaemons and TrollStore, and
   `com.apple.springboard.debugapplications` is present. Inject, walk
   `UIApplication` windows via `UIAccessibility` properties, answer over a local
   socket vphoned proxies.
4. **Stay on OCR.** Record why here, and the agent keeps working unchanged —
   see below.

## Why the agent does not block on this

`VPhoneJevObserver.swift` defines one `JevObservation` struct and two providers
behind it. `VPhoneHostControl.observe()` prefers the accessibility provider and
falls back to OCR when it yields nothing:

```
accessibility tree → JevObservation ─┐
                                     ├─→ VPhoneJevAgent (unchanged either way)
Vision OCR         → JevObservation ─┘
```

Every response carries `source`, so it is always visible which one ran. Landing
the tree is a provider swap, not an agent rewrite.

## Runbook

Everything on the host side is built and compiling; what remains needs two
things only the machine's owner can provide.

### Blockers

| | required | current |
|---|---|---|
| SIP / AMFI | disabled | **enabled** — `csrutil status`, no boot-args |
| free disk | ~60–100 GB (IPSWs, extraction, VM disk) | **16 GB** |

SIP is disabled from Recovery (⌘R at boot → Terminal → `csrutil disable`,
plus `nvram boot-args=-arm64e_preview_abi amfi_get_out_of_my_way=1`), then
reboot. Neither can be done from inside a running session.

### Already prepared

- `scripts/repos/trustcache` and `scripts/repos/insert_dylib` cloned
- `vphoned_accessibility.m` written and compiling for `arm64 iphoneos`
- `VPhoneControl.accessibilityProbe/Enable/Tree` wired, `ax_probe` exposed on
  the automation socket, `JevAccessibilityProvider` consuming it

### Sequence once unblocked

```sh
make setup_tools                  # brew deps, build toolchain, venv
make fw_prepare                   # download + merge IPSWs  (the disk-hungry step)
make fw_patch_jb                  # JB variant: needed for the injection fallback
make vm_new && make cfw_install_jb
make boot                         # VM window + automation socket

make jev_probe                    # ← the spike: what the firmware exposes
```

Record `jev_probe` output in Findings below **before** trusting the tree, then:

```sh
make jev PROMPT="set an alarm for 6 AM"    # real Clock app, real AX tree
```

### Why this is the path

Two routes to a semantic tree were closed by measurement, not assumption:

- **iOS Simulator host AX** — the device screen is a single `AXGroup` with no
  children, and both `AXManualAccessibility` and `AXEnhancedUserInterface`
  are rejected (`-25205`, `-25208`). Simulator.app publishes only its own
  macOS chrome.
- **idb** — `idb-companion` is no longer in Homebrew; the project is
  effectively unmaintained.

XCUITest can reach the Simulator's tree, but each query needs a test-runner
invocation measured in seconds, which is unusable in a per-step agent loop.

The VM is also the only target with the **real Clock app** — the Simulator
ships no `com.apple.mobiletimer` at all — and with a working key-event path
for text entry (`VPhoneKeyHelper.typeString`).

## Findings

> Not yet run — no VM exists in this checkout. Record probe output, firmware
> build, and what worked here.

```
date:
firmware build:
variant (regular/dev/jb/exp):
probe output:

conclusion:
```

## Validation

Once the tree returns elements:

1. **Parity.** Same screen through both providers. The tree should report
   strictly more than OCR — at minimum, switch states OCR cannot see.
2. **Toggle state is real.** Read Airplane Mode's `value` off, flip it, read it
   on. This is the capability OCR fundamentally lacks.
3. **Icon-only controls appear.** A screen whose primary control has no text
   label should still produce a tappable element.
4. **Frames map to taps.** Element centres should land on the control —
   verify against `injectTap`'s pixel space (top-left origin, screenshot
   dimensions).
5. **Agent unchanged.** `make jev_fake` and a real `make jev` run should behave
   the same way modulo better observations.
