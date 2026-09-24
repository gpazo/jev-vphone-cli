# Observation follow-up — 2026-09-22

A short real-app task reached the 1–2 second range: from the open Display & Text
Size pane, Jev enabled Bold Text and Increase Contrast in **1.866 seconds**.
Both native switch values and saved preferences independently confirmed the
change. The reverse goal took **2.543 seconds**, including an extra Contrast
toggle, and restored the original settings. This demonstrates a fast short
task, not a measured general speedup over the previous controller.

[Original-speed Settings video](artifacts/jev-settings/20260922-181231/jev-settings-timed.mp4)

## What remains in the code

1. **Hand the fresh completion observation to the next decision.** A changed
   completion check previously fetched a full screen, discarded it, and fetched
   another immediately. The loop now consumes that already-complete read once.
   No input occurs between the handoff and the next judgment. A later action
   still revalidates its target; a later completion still requires another fresh
   read. This is one local pending observation, not a cache or another state
   memory system. The regression tests require three reads instead of four
   across a changed-completion/rejudgment sequence and reject another change
   during the subsequent judgment.
2. **Missing remote content cannot certify completion.** The pinned idb reader
   can leave a visible, childless `AXRemoteElement` after a cross-process snapshot
   fails while reporting `ok=true, truncated=false`. The simulator marks this
   observation incomplete; both initial and fresh completion evidence must be
   complete. Local controls remain available, and the model is told about the
   missing content. This is a native surface check, with no app names or task
   rules. The conservative stop can reject a task when unavailable embedded
   content is irrelevant; it does not prove all other trees are complete.
3. **Account for completion reads explicitly in timing.** They previously
   appeared in the next step's observation total, obscuring the redundant read.

The guest input helper and serial hit-test implementation are unchanged from
before this turn. No OCR, generated coordinates, app-specific controller plan,
new execution mode, or parallel input was introduced.

The idb boundary behavior is documented in its
[actual snapshot implementation](https://github.com/facebook/idb/blob/v1.6.1/SimulatorFrameworkBridge/AccessibilityService.m).
A subtree failure silently leaves a stub; the envelope's truncation bit only
reports budget/depth limits. This is separate from a normal blank document.

## Final-build device results

Binary SHA-256: `2409cd72df8e0b3ccbb2c3bff20fe9476c8688f08cbdaf86930b91ea28db25a1`.
iOS 26.5, device `108417FD-4FA3-4315-9587-0F4A0469E561`.

| Task | Outcome | Timing from goal |
|---|---|---|
| Settings: both on | Both AX values and preferences 0→1 | Report 1.866 s; 3 Jev calls, median 287 ms |
| Settings: both off | Both AX values and preferences 1→0; one extra toggle | Report 2.543 s; 5 calls, median 228 ms |
| Contacts: Theo Moss / Jev speed test | New ID 21; all 20 existing records preserved | Saved 4.518 s; report 6.812 s; 7 calls, median 265 ms |
| Safari: Google → first → Back → second | Second page independently observed, then extra scroll; final embedded content unavailable; **controller stopped instead of claiming success** | Second observed 11.656 s; stopped 18.092 s |

The Settings goals were separate runs in one ready session; their video joins
them at original speed and resets the timer. Startup, prior navigation and
post-run external auditing are excluded from goal-to-report times. The pane
was already open. Each segment has a 1.5-second final hold; output starts at
PTS zero. Native values and `EnhancedTextLegibilityEnabled` / `DarkenSystemColors`
all agreed. These are single runs, not latency percentiles.

Contacts started at the list and used Add → three fills → Done. Its full
[video and evidence](artifacts/jev-contacts/20260922-181515/jev-contacts-timed.mp4)
remain available. The latest Safari failure is
[retained with its independent audit](artifacts/jev-safari/20260922-180956/result.json).
Neither the Safari 1–2 second target nor a reliable cross-app speedup is met.

## Experiments rejected

- Asking the snapshot for native `IsVisible` cost 1.781 s on a small Contacts
  tree, versus 0.039 s for a subsequent ordinary read. `VisiblePoint` cost
  1.687 s. These individual readings do not support replacing live hit tests
  with those whole-tree attributes. Raw trees are in `artifacts/jev-visibility/`.
- A bounded four-worker hit-test batch matched the independent reader on settled
  Contacts detail/editor and Safari screens, including reordered and repeated
  points. One 80-point document comparison measured median 218→160 ms. Live
  navigation did not establish sufficient benefit/reliability to retain it.
  The prototype, benchmark script and results are archived under
  `artifacts/jev-hit-batch/`; none of its implementation remains in the default
  controller or helper.
- Initial Safari old/new runs `175107` / `175151` both passed at 28.599 / 22.862 s,
  but used different actions and included the now-retired batch experiment.
  They are **not** evidence of the final implementation's speedup.
- With the revised audit, baseline `175347` passed at 21.579 s. Prototype
  `175511` claimed success at 19.332 s while the independent tree lost the page
  body; it failed. Subsequent prototype runs `180103`, `180251`, `180347` and
  held-out Swift query `180545` also failed. `180005` failed during cold setup.
- Baseline `180433` navigated the full route at 22.120 s but the strict stop
  evaluator rejected an acknowledged wait after the second-page milestone.
  The stop evaluator currently includes waits among late controller actions.
- Matched Contacts list trials `175810` (baseline) / `175853` (prototype) both
  preserved existing records, at 6.211 / 6.200 s. There was effectively no total
  latency benefit. The final build's 6.812 s Contacts result likewise does not
  establish a whole-task gain.
- An accessibility automation-mode probe did not restore the missing document;
  automation mode was restored. No traversal-mode heuristic was adopted.

## Evaluation overhead and validation

The Safari evaluator now verifies example.com readiness before starting the
controller. After independently observing all four route milestones it pauses
continuous full-tree polling, then obtains a **new final tree after completion**.
Action timestamps still check late steps. Read durations and the final audit
are recorded separately. This changes evaluation load, not production speed;
use the same recorder for comparisons. Final video annotations distinguish
controller completion from this final check. Other audit limitations remain,
including a result ranking frozen while Google may still be loading and
milestone times measured at read completion rather than exact browser paint.

43 focused Swift tests and 19 Python evaluator/command checks passed. Signed
release and simulator builds succeeded; release signature verification passed.
The live final Safari failure exercised the new incomplete-content guard.
Settings and Contacts passed independent state checks. No firmware patches or
BundleOps disk-image tests were run.

The next substantial latency work belongs in the native reader: report remote
subtree failures explicitly, then investigate genuinely scoped native reads or
retained native target identities. Cutting an already-fetched JSON tree cannot
remove the expensive native traversal. A new backend must demonstrate equivalent
modal, duplicate-label, moving-target and completion behavior before promotion.
