# Scoped native validation experiment

`JEV_SCOPED_VALIDATION=1` enables observation-scoped native references in the
simulator controller. **It is off by default.** Run `make setup_jev` and
`make patcher_build` before trying it. The normal controller remains the fallback
when the experiment is disabled or cannot prove a target's identity/context.

The helper captures targets serially, retaining actual native identities and
their ancestry. Before input it reads the foreground application root and
rechecks the selected target's ancestry, values, context and display-wide hit.
The input helper checks again and consumes the reference. A new observation
invalidates old references. Web documents, incomplete observations, ambiguous
semantic identities and mismatched capture context do not take this shortcut.
Completion always uses the existing full fresh observation.

This is **not** a proven replacement for full validation across arbitrary apps.
Moving controls, recycled same-label cells, cross-process overlays and remote
content need broader live equivalence coverage. The existing full-read tests
still cover moved targets; that does not prove the new private-API path.

## Checks

Open Settings > Accessibility > Display & Text Size, then:

```sh
python3 tests/NativeValidation/guards.py
```

The six live checks use independent AX reads, flip Bold Text and restore its
initial value. No Jev calls occur. Results go under
`research/artifacts/jev-native-validation/`.

`Probe.m` and `check.py` are the smaller **read-only feasibility probe**, not the
shipped helper. The probe does not check all controller context guards; its
timings alone are not production validation timings. Build/run it with:

```sh
xcrun --sdk iphonesimulator clang -fobjc-arc -O2 -arch arm64 \
  -mios-simulator-version-min=15.0 -framework Foundation \
  tests/NativeValidation/Probe.m -o /tmp/jev-native-validation-probe
python3 tests/NativeValidation/check.py 'Bold Text' --type 40
# Or, with the Contacts new-contact editor open:
python3 tests/NativeValidation/check.py 'First name' --type 49 --batch
```

See [the full comparison](../../research/jev_scoped_validation.md), including
the slower Settings results and failed Calendar runs. No concurrent builds or
video rendering ran during recorded task timing.
