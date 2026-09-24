# Observation cost — 2026-09-20

This follow-up profiles the general accessibility controller. No OCR, app-specific
navigation, threshold changes, or relaxed target/completion checks were added.

## Finding and fix

`--profile` now separates the native tree request, local decoding/title lookup,
and live hit tests. Every successful read reports its hit count, retry index,
and whether it used a snapshot or fresh traversal. These are nested diagnostics:
do not add them to the existing stage totals, which already include this work.
The hit-test interval excludes retry sleeps and subsequent reads.

The title finder used recursive `lazy.compactMap(...).first`. Swift's lazy
filter/map finds a matching index and then fetches its value, evaluating the
successful transform twice. Recursing that pattern multiplies work with nesting.
A plain early-return loop visits each candidate branch once and preserves the
first nonempty native web title. A 24-level regression case covers nested titles,
empty titles, competing titles and native screens without a document.

Frozen native-tree comparison (`artifacts/jev-observation/title-traversal.json`):

| Tree | Old calls | New calls | Old time | New time | Same title |
|---|---:|---:|---:|---:|---|
| No document | 135 | 135 | 3.13 ms | 0.39 ms | Yes |
| Example Domain | 65,791 | 20 | 156.88 ms | 0.074 ms | Yes |
| Swift Programming Language | 65,791 | 20 | 173.17 ms | 0.073 ms | Yes |

Replay with `swift tests/jev_title_benchmark.swift <audit.json> ...`. This script
contains frozen old/new algorithms to isolate their cost; production-path
evidence comes from the live profiler and focused Swift regression suite.

The instrumented baseline had 23 reads with median local decoding of 187.6 ms.
The subsequent live pass had 48 reads with median decoding of 11.25 ms; local
decoding totaled 3.482 s versus 0.517 s despite the extra reads. The paths and
page states differ, so these are diagnostic measurements, not an end-to-end
controlled speedup. Saved aggregates: `artifacts/jev-observation/live-profile.json`.

## Live results

All runs use the default corroborated completion policy. Safari recordings
include a concurrent independent AX audit and exact Jev requests/responses.

| Artifact | Task | Agent time | Result |
|---|---|---:|---|
| jev-safari/20260920-183654 | Swift search, before title fix | 17.440 s | Incomplete; malformed chosen-action distribution rejected after Back and scroll |
| jev-safari/20260920-183934 | Swift search, after title fix | 23.750 s | Sequence and endpoint verified; correct completion claim |
| jev-safari/20260920-184038 | Python search, after title fix | 7.537 s | Incomplete; stopped at human-decision gate, blocked probability 0.46 |
| jev-alarm/20260920-184106 | 6 AM | 3.261 s | New 06:00 record, correct completion claim |
| jev-alarm/20260920-184113 | 12 PM | 3.274 s | New 12:00 record, correct completion claim |
| jev-alarm/20260920-184120 | 6 PM | 3.325 s | New 18:00 record, correct completion claim |

Google's organic order in the Swift pass was swift.org then developer.apple.com,
different from the earlier Wikipedia runs. Independent milestones returned at
5.535 s (results), 11.008 s (first), 13.382 s (Back), 21.786 s (second). Completion
was deferred once when the fresh tree changed; the final controller report was
23.750 s. Final state remained the second destination. Startup was 1.442 s,
excluded. The timed video preserves original speed and extends the final still.

Alarm startup was 2.207 s, excluded. All existing records were preserved. These
are the unchanged demo app's saved alarms, not Apple Clock notifications.
The Python failure is retained; faster decoding does not establish reliable
judgment or arbitrary-app completion. The previous 26.179 s Safari pass is
historical context, not a matched baseline for the 23.750 s pass.

## Experiments not promoted

Requesting just label/value/type for hit tests preserved all 36 hit results in
six alternating comparisons on a stable page. Median batch cost was 49.44 ms
with full attributes versus 45.81 ms with reduced attributes. This was small
beside transition costs, so the production request remains unchanged.

A 0.6 s drag with 60/30/12 motion events cost 1.85–2.00 / 1.18–1.76 /
1.18–1.59 s in two trials per setting. All moved the page, but Wikipedia's
accessible content and scroll extent changed between reloads. This is not a
controlled equivalence result. The production gesture remains at 60 events.
Raw trees, logs and measurements are under `artifacts/jev-observation/`.

## Next bottleneck

Native reads and hit tests during transitions remain expensive and variable.
In the post-fix Swift run they totaled 7.638 s and 8.856 s across 48 reads.
The audit adds concurrent device load. Repeated decoding is fixed; investigate
fewer redundant native calls and coherent readiness without removing occlusion,
target freshness, or terminal verification. A controlled static scrolling fixture
would be needed before changing the gesture sampling rate.

## Validation

32 focused Swift tests and 14 Python command/oracle tests passed. `make build`
completed and the release binary passed strict signature verification.
`git diff --check` passed. Live runs used the simulator debug build; release
signing was checked separately. No firmware or binary patches were introduced.
