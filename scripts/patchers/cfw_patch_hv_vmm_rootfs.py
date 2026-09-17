"""Rootfs-side orchestrator for the hv_vmm_present user-mode patch
(blacklist-flip design, standalone-binary side).

Companion to:
  - The kernel-side `KernelJBPatchHvVmmRename` (renames the OID name
    cstring from `hv_vmm_present` to `Xv_vmm_present` AND mangles
    every kernel-internal `\\0kern.hv_vmm_present\\0` cstring inside
    kexts so they query the new name and keep seeing 1).
  - The DSC-side `cfw_patch_hv_vmm_dsc.py` (same blacklist-flip,
    mangles every DSC dylib's cstring EXCEPT those in
    `DONT_PATCH_INSTALL_NAMES`).

This module covers the third domain: standalone Mach-O binaries on
the device's rootfs that hard-code `"kern.hv_vmm_present\\0"` in their
own `__TEXT,__cstring`. Under the new design every such binary needs
to either:

  - Be MANGLED (byte 5 of the cstring: 'h' -> 'X') so it queries
    `kern.Xv_vmm_present`, gets the truthful `1` back from the
    renamed OID, and behaves as it would on a real device. Default
    behaviour: most platform daemons (watchdogd, mobile_obliterator,
    DumpPanic, …) need this — without it they hit the renamed OID's
    ENOENT, interpret as "not in a VM", and take real-hardware code
    paths that don't exist on the VM (concrete repro: watchdogd
    SIGTRAP → kernel panic with `watchdogd[N] exited`).

  - Be LEFT ALONE (`DONT_PATCH_ROOTFS_PATHS` blacklist) so its
    cstring still says `kern.hv_vmm_present`, that query returns
    ENOENT after the kernel rename, the binary's defensive
    post-call check leaves the cached `is_vmm` byte at BSS-zero (0),
    and the binary thinks "not in a VM". Use this for the sign-in
    / activation / Apple-ID stack — the same role intent we apply
    to the DSC frameworks they link.

Data sources for ALL_KNOWN_ROOTFS_PATHS
---------------------------------------
The list below is taken verbatim from a `grep -rla 'kern\\.hv_vmm_present'
ipsws/iPhone17,3_26.1_23B85_Restore_extracted/ --exclude-dir='Cryptexes'`
on the extracted rootfs of iPhone17,3 26.1 23B85, minus
`/System/Library/Caches/com.apple.kernelcaches/kernelcache.release.iphone17`
which is the kernel itself and is patched by the firmware patcher
not this module. If future iOS builds add new daemons that reference
the cstring, re-run that grep and add the new paths here.
"""

import sys


# ─────────────────────────────────────────────────────────────────────
# Complete list of rootfs Mach-Os that contain the cstring
# `kern.hv_vmm_present\0` somewhere in their __TEXT,__cstring.
#
# Established once by scanning the extracted rootfs of iPhone17,3 /
# iOS 26.1 / 23B85. Re-derive when porting to a new iOS build by:
#   grep -rla 'kern\.hv_vmm_present' \
#       ipsws/<new>_Restore_extracted/ \
#       --exclude-dir='Cryptexes' 2>/dev/null
# ─────────────────────────────────────────────────────────────────────
ALL_KNOWN_ROOTFS_PATHS: tuple[str, ...] = (
    # /usr/libexec daemons
    "/usr/libexec/adid",
    "/usr/libexec/DumpPanic",
    "/usr/libexec/fairplaydeviceidentityd",
    "/usr/libexec/mmaintenanced",
    "/usr/libexec/modelmanagerd",
    "/usr/libexec/mobile_obliterator",
    "/usr/libexec/mobileactivationd",
    "/usr/libexec/networkserviceproxy",
    "/usr/libexec/promotedcontentd",
    "/usr/libexec/storagekitd",
    "/usr/libexec/terminusd",
    "/usr/libexec/transparencyd",
    "/usr/libexec/trustd",
    "/usr/libexec/watchdogd",

    # /usr/sbin
    "/usr/sbin/absd",
    "/usr/sbin/bluetoothd",
    "/usr/sbin/fairplayd.H2",

    # /usr/lib
    "/usr/lib/libMobileGestalt.dylib",

    # /System/Library/CoreServices
    "/System/Library/CoreServices/ClarityBoard.app/ClarityBoard",

    # /System/Library/DataClassMigrators
    "/System/Library/DataClassMigrators/MobileActivationMigrator.migrator/MobileActivationMigrator",

    # /System/Library/ExtensionKit
    "/System/Library/ExtensionKit/Extensions/HostInferenceProviderService.appex/HostInferenceProviderService",

    # /System/Library/Frameworks
    "/System/Library/Frameworks/CoreML.framework/CoreML",
    "/System/Library/Frameworks/CoreVideo.framework/CoreVideo",
    "/System/Library/Frameworks/ManagedAppDistribution.framework/Support/managedappdistributiond",
    "/System/Library/Frameworks/MediaToolbox.framework/MediaToolbox",
    "/System/Library/Frameworks/SoundAnalysis.framework/SoundAnalysis",
    "/System/Library/Frameworks/StoreKit.framework/Support/storekitd",

    # /System/Library/PrivateFrameworks
    "/System/Library/PrivateFrameworks/AAAFoundation.framework/AAAFoundation",
    "/System/Library/PrivateFrameworks/AirPlaySupport.framework/AirPlaySupport",
    "/System/Library/PrivateFrameworks/AppStoreDaemon.framework/Support/appstored",
    "/System/Library/PrivateFrameworks/AppStoreUtilities.framework/AppStoreUtilities",
    "/System/Library/PrivateFrameworks/AppleNeuralEngine.framework/AppleNeuralEngine",
    "/System/Library/PrivateFrameworks/ApplePushService.framework/ApplePushService",
    "/System/Library/PrivateFrameworks/ApplePushService.framework/apsd",
    "/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit",
    "/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture",
    "/System/Library/PrivateFrameworks/CoreALD.framework/CoreALD",
    "/System/Library/PrivateFrameworks/CoreCDP.framework/CoreCDP",
    "/System/Library/PrivateFrameworks/CorePrescription.framework/CorePrescription",
    "/System/Library/PrivateFrameworks/CorePrescription.framework/XPCServices/CorePrescriptionService.xpc/CorePrescriptionService",
    "/System/Library/PrivateFrameworks/CoreRE.framework/CoreRE",
    "/System/Library/PrivateFrameworks/DVTInstrumentsUtilities.framework/DVTInstrumentsUtilities",
    "/System/Library/PrivateFrameworks/DataDetectorsUI.framework/PlugIns/com.apple.DataDetectorsUI.ActionsExtension.appex/com.apple.DataDetectorsUI.ActionsExtension",
    "/System/Library/PrivateFrameworks/DeviceCheckInternal.framework/DeviceCheckInternal",
    "/System/Library/PrivateFrameworks/DeviceIdentity.framework/DeviceIdentity",
    "/System/Library/PrivateFrameworks/EmailFoundation.framework/EmailFoundation",
    "/System/Library/PrivateFrameworks/Espresso.framework/Espresso",
    "/System/Library/PrivateFrameworks/FindMyBase.framework/FindMyBase",
    "/System/Library/PrivateFrameworks/IDS.framework/identityservicesd.app/identityservicesd",
    "/System/Library/PrivateFrameworks/IDSFoundation.framework/IDSFoundation",
    "/System/Library/PrivateFrameworks/IOSurfaceAccelerator.framework/IOSurfaceAccelerator",
    "/System/Library/PrivateFrameworks/MagnifierSupport.framework/MagnifierSupport",
    "/System/Library/PrivateFrameworks/MobileActivation.framework/MobileActivation",
    "/System/Library/PrivateFrameworks/NeuralNetworks.framework/NeuralNetworks",
    "/System/Library/PrivateFrameworks/PhotoFoundation.framework/PhotoFoundation",
    "/System/Library/PrivateFrameworks/Recon3D.framework/Recon3D",
    "/System/Library/PrivateFrameworks/RenderBox.framework/RenderBox",
    "/System/Library/PrivateFrameworks/SonicKit.framework/SonicKit",
    "/System/Library/PrivateFrameworks/TrialServer.framework/TrialServer",
    "/System/Library/PrivateFrameworks/VFX.framework/VFX",
    "/System/Library/PrivateFrameworks/VideosUI.framework/VideosUI",
    "/System/Library/PrivateFrameworks/VisionKitCore.framework/VisionKitCore",
    "/System/Library/PrivateFrameworks/WatchdogServiceManagement.framework/WatchdogServiceManagement",
    "/System/Library/PrivateFrameworks/caulk.framework/caulk",

    # /Applications
    "/Applications/CheckerBoard.app/CheckerBoard",
    "/Applications/Family.app/Family",
    "/Applications/PeopleMessageService.app/PeopleMessageService",
    "/Applications/PeopleViewService.app/PeopleViewService",
    "/Applications/StoreKitUISceneService.app/StoreKitUISceneService",
)


# ─────────────────────────────────────────────────────────────────────
# Rootfs binaries to LEAVE UNPATCHED.
#
# A path in this set keeps its `kern.hv_vmm_present\0` cstring as-is.
# After the kernel rename that sysctl name returns ENOENT, the caller's
# defensive post-call check leaves the cached `is_vmm` byte at BSS-zero
# (0), and the binary thinks "not in a VM". Use this for sign-in /
# Apple-ID / activation / Store consumers — mirrors the DSC blacklist.
#
# Starting set is intentionally conservative: only daemons we have a
# clear "is sign-in adjacent" reason to leave alone. Tighten / loosen
# by editing this list and re-running `make cfw_install_jb`.
# ─────────────────────────────────────────────────────────────────────
DONT_PATCH_ROOTFS_PATHS: frozenset[str] = frozenset((
    # Apple ID / activation / device-identity daemons
    "/usr/libexec/adid",
    "/usr/libexec/mobileactivationd",
    "/usr/libexec/fairplaydeviceidentityd",
    "/System/Library/DataClassMigrators/MobileActivationMigrator.migrator/MobileActivationMigrator",
    # APNS / iMessage daemons
    "/System/Library/PrivateFrameworks/ApplePushService.framework/apsd",
    "/System/Library/PrivateFrameworks/IDS.framework/identityservicesd.app/identityservicesd",
    # Store / IAP daemons + UI
    "/System/Library/Frameworks/StoreKit.framework/Support/storekitd",
    "/System/Library/PrivateFrameworks/AppStoreDaemon.framework/Support/appstored",
    "/Applications/StoreKitUISceneService.app/StoreKitUISceneService",
    "/Applications/CheckerBoard.app/CheckerBoard",
    # Health Rx
    "/System/Library/PrivateFrameworks/CorePrescription.framework/XPCServices/CorePrescriptionService.xpc/CorePrescriptionService",
    # Standalone copies of DSC-blacklisted frameworks. The rootfs files
    # may be stubs that redirect into the DSC at load time, in which
    # case mangling them has no effect — but blacklisting is defensive
    # and matches role intent.
    "/System/Library/PrivateFrameworks/AAAFoundation.framework/AAAFoundation",
    "/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit",
    "/System/Library/PrivateFrameworks/IDSFoundation.framework/IDSFoundation",
    "/System/Library/PrivateFrameworks/DeviceIdentity.framework/DeviceIdentity",
    "/System/Library/PrivateFrameworks/DeviceCheckInternal.framework/DeviceCheckInternal",
    "/System/Library/PrivateFrameworks/MobileActivation.framework/MobileActivation",
    "/System/Library/PrivateFrameworks/ApplePushService.framework/ApplePushService",
    "/System/Library/PrivateFrameworks/AppStoreUtilities.framework/AppStoreUtilities",
    "/System/Library/PrivateFrameworks/CorePrescription.framework/CorePrescription",
    "/System/Library/PrivateFrameworks/CoreCDP.framework/CoreCDP",
    "/System/Library/PrivateFrameworks/EmailFoundation.framework/EmailFoundation",
    "/System/Library/PrivateFrameworks/FindMyBase.framework/FindMyBase",
    "/System/Library/PrivateFrameworks/TrialServer.framework/TrialServer",
    "/System/Library/PrivateFrameworks/DVTInstrumentsUtilities.framework/DVTInstrumentsUtilities",
    "/System/Library/PrivateFrameworks/WatchdogServiceManagement.framework/WatchdogServiceManagement",
))


def get_patch_paths() -> list[str]:
    """Return the list of rootfs binary paths that should be byte-5
    mangled at install time. This is `ALL_KNOWN_ROOTFS_PATHS` minus
    `DONT_PATCH_ROOTFS_PATHS`, in stable sorted order.
    """
    return sorted(p for p in ALL_KNOWN_ROOTFS_PATHS if p not in DONT_PATCH_ROOTFS_PATHS)


def main(argv: list[str]) -> int:
    """Print the patch paths, one per line, for shell consumption."""
    for p in get_patch_paths():
        print(p)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
