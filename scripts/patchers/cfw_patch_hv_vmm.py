"""hv_vmm_present user-mode patch module — cstring-mangle approach.

Mangles the cstring "kern.hv_vmm_present\\0" in targeted user-mode
binaries so they query a kernel sysctl with a different name. On a
kernel patched by `KernelJBPatchHvVmmRename` (which renames the OID
from `hv_vmm_present` to `Xv_vmm_present`), the new design is:

  - Caller queries `kern.hv_vmm_present` (UNPATCHED binary):
        kernel returns ENOENT. The canonical defensive post-call check
        (`cbnz w0, skip` / `cmp w0,#0 ; b.ne skip`) takes the skip
        path; the cached `is_vmm` byte stays at BSS-zero (0). The
        binary thinks it is NOT running in a VM.

  - Caller queries `kern.Xv_vmm_present` (PATCHED binary):
        kernel returns 1 (the real value of the OID's int variable).
        The defensive check passes; the cache stores 1. The binary
        thinks it IS running in a VM — same as a stock device.

Patch shape (per cstring occurrence): byte 5 of the cstring
`'h'` (0x68) → `'X'` (0x58). The mangled cstring is
`"kern.Xv_vmm_present\\0"`. Byte 5 is chosen so the `kern.` top-level
sysctl namespace is preserved — without that, the kernel's
name-to-MIB resolver wouldn't route the call to any OID.

Public entrypoints:
    patch_hv_vmm(filepath, *, dry_run=False) -> int
        Patch a standalone Mach-O. Returns the number of cstring sites
        mangled.

    find_string_sites(data: bytes) -> list[dict]
        Find every cstring occurrence in an in-memory Mach-O.
"""

import struct

from .cfw_asm import parse_macho_sections, _log_asm


NEEDLE = b"kern.hv_vmm_present\x00"
# Mangle byte offset (0-based within NEEDLE). Position 5 is the 'h' of
# "hv_vmm_present" — the first byte after the "kern." namespace prefix.
# Keeping the "kern." prefix intact ensures the kernel's sysctl name-to-MIB
# resolver routes the call to a real OID (registered as `Xv_vmm_present`
# under `kern` by the companion kernel patch). Byte 0 would have produced
# `Xern.hv_vmm_present`, which can never resolve because `Xern` isn't a
# registered top-level sysctl namespace.
MANGLE_OFFSET = 5
ORIGINAL_BYTE = b"h"  # 0x68
MANGLED_BYTE = b"X"   # 0x58
MANGLED_NEEDLE = NEEDLE[:MANGLE_OFFSET] + MANGLED_BYTE + NEEDLE[MANGLE_OFFSET + 1:]


def find_string_sites(data):
    """Return all unmangled "kern.hv_vmm_present\\0" cstring occurrences.

    Each entry: {string_vma, file_offset, section}.

    Hits are anchored at a cstring boundary (preceded by a NUL byte or
    at the start of the section) so partial-match substrings inside
    longer cstrings won't be returned.
    """
    sections = parse_macho_sections(data)
    out = []
    for sec_name, (vma, size, foff) in sections.items():
        _, _, sect = sec_name.partition(",")
        # __cstring is where the linker puts unique C-string literals.
        # Some method-name / class-name pools could in principle hold
        # the same bytes too; we include them for safety.
        if sect not in ("__cstring", "__objc_methname", "__objc_classname"):
            continue
        buf = bytes(data[foff:foff + size])
        i = 0
        while True:
            p = buf.find(NEEDLE, i)
            if p < 0:
                break
            if p == 0 or buf[p - 1] == 0:
                out.append(
                    {
                        "string_vma": vma + p,
                        "file_offset": foff + p,
                        "section": sec_name,
                    }
                )
            i = p + 1
    return out


def is_already_mangled(data):
    """Detect whether the binary already contains the mangled form.

    Used purely for friendlier logging — `find_string_sites` already
    returns empty on a mangled binary, so the patch flow is idempotent
    regardless.
    """
    return bytes(data).find(MANGLED_NEEDLE) >= 0


def patch_hv_vmm(filepath, *, dry_run=False):
    """Mangle the kern.hv_vmm_present cstring in a standalone Mach-O.

    Returns the count of mangled cstring sites. Idempotent.
    """
    data = bytearray(open(filepath, "rb").read())
    sites = find_string_sites(bytes(data))
    if not sites:
        if is_already_mangled(bytes(data)):
            print(f"  [.] {filepath}: already mangled (no original "
                  f"'kern.hv_vmm_present' cstring present)")
        else:
            print(f"  [.] {filepath}: 'kern.hv_vmm_present' cstring not "
                  f"present — nothing to do")
        return 0

    print(f"  [+] {len(sites)} cstring occurrence(s) in {filepath}")
    n = 0
    for s in sites:
        foff = s["file_offset"]
        original = bytes(data[foff:foff + len(NEEDLE)])
        # Idempotence: if byte at MANGLE_OFFSET is already mangled, skip.
        if original[MANGLE_OFFSET:MANGLE_OFFSET + 1] == MANGLED_BYTE:
            print(f"  [.] string@0x{s['string_vma']:X} already mangled "
                  f"(byte {MANGLE_OFFSET} is already {MANGLED_BYTE.decode()!r})")
            continue
        if original != NEEDLE:
            print(f"  [-] string@0x{s['string_vma']:X} bytes look unexpected "
                  f"({original!r}); skipping")
            continue
        print(f"  patching string@0x{s['string_vma']:X} (sect={s['section']}): "
              f"byte {MANGLE_OFFSET} {ORIGINAL_BYTE.decode()!r} -> "
              f"{MANGLED_BYTE.decode()!r}  "
              f"('kern.hv_vmm_present' -> 'kern.Xv_vmm_present')")
        data[foff + MANGLE_OFFSET:foff + MANGLE_OFFSET + 1] = MANGLED_BYTE
        n += 1

    if dry_run:
        print(f"  [.] dry-run — not writing back")
        return n
    if n > 0:
        open(filepath, "wb").write(data)
        print(f"  [+] {filepath}: mangled {n} cstring occurrence(s)")
    return n
