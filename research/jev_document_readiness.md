# Document readiness and a clean Safari sequence — 2026-09-21

The general controller now gives a temporarily missing document time to return
within the existing bounded settling budget. This applies to native navigation
controls as well as links. Previously, a Back transition exposed only browser
chrome; Jev scrolled on that transient observation and the next page reading
was attached to the scroll instead of Back.

The change retains the preceding document/app and waits only when the same app
has lost its document and has no editable field. Native text editing and a
change to another app remain immediately eligible for judgment. No app name,
search-result order, URL, or task plan appears in this rule. The existing 2.5 s
settling budget is unchanged; native non-editable panels can still consume that
budget before being offered. No new model prompt, memory table, or mode was added.

## Live results

Both runs start from a ready session in Safari on example.com. Session startup
is excluded; all browsing, model calls, execution checks, and completion checks
are included in the goal-to-report time.

| Query | Required destinations, independently ranked | Time | Navigation | Stop immediately after loading second page |
|---|---|---:|---|---|
| swift programming language | swift.org → Back → developer.apple.com | 30.400 s | Verified | Verified |
| python programming language | python.org → Back → Wikipedia | 38.087 s | Verified | Failed: one extra scroll |

Artifacts and original-speed videos:

- [Swift, clean sequence and stop](artifacts/jev-safari/20260921-184259/jev-safari-timed.mp4)
- [Python, correct sequence but late stop](artifacts/jev-safari/20260921-184421/jev-safari-timed.mp4)

The independent native reader confirmed result order, destination title,
address, content, return to the same query, and the final page. Both audits had
no read errors. Jev reported completion in both runs. The stricter stop audit
rejects Python's extra input, despite that completion claim. Original result
files are preserved as `result-before-stop-audit.json`.

The Python second page was observed at 28.197 s. A scroll started at 29.543 s,
was acknowledged at 33.473 s, and Jev stopped at 38.087 s. The evaluator now
matches acknowledged actions to their attempt times, so a navigation action
that merely acknowledges after its destination loads is not falsely counted
as a new input. Exit status now also requires no later acknowledged input begun
after the second page was observed.

These are two subsequent trials, not a matched old/new success-rate study.
Previous failed Safari trials remain in the [input evaluation](jev_simple_input.md).
The final implementation adds an app-scope bypass after these trials; all their
observations were in Safari, so that bypass does not change their exercised path.
A focused test checks switching to another app without waiting.

## Where the time went

| Component | Swift | Python |
|---|---:|---:|
| Jev decisions, total | 3.418 s | 3.063 s |
| Jev decision median | 207 ms | 262 ms |
| Input and its checks | 10.096 s | 9.641 s |
| Observation and settling | 16.219 s | 24.674 s |

Swift used 15 decisions; Python used 11. The remaining time includes completion
freshness checks and logging. There was no build during either live run.
This is evidence of successful navigation, not a new latency record: previous
iOS 18.5 Safari runs were faster. Native reads/input remain the main cost.

The goal stopwatch uses monotonic timestamps. These two captures predate saving
the video-to-goal offset, so their overlays align with recording start; the
small pre-goal recording interval was not separately measured. The recorder now
saves that offset and the reusable annotator applies it on future recordings.
Video playback is original speed, with a two-second final hold.

## Prompt experiments rejected

On the saved failing decision with Apple Developer already available, three
calls per variant all still chose scroll down:

- Original request.
- Shorter rules without duplicated operation target lists.
- Removal of read-only numeric values.
- Corrected Back destination in history using the subsequently observed page.
- One choice combining operation and bound target.
- Additional read-only document text.

Requests and responses live in `artifacts/jev-kiss-prompt/20260921/`.
The latter two observation/history experiments replay previously captured
information; they are not independent device trials. None justified a prompt
or action-vocabulary change. No frozen-replay modifications were fed into the
live runs.

## Validation

35 focused Swift tests passed, including document disappearance after a native
button, readiness of editable native UI, switching to another app, preserved
navigation history, and completion freshness. Seven Safari evaluator tests and
four Donpa evaluator tests passed. Debug and signed release builds completed;
release signature verification passed. Final video frames were visually checked
against the independently observed destination pages. No full BundleOps suite
was run.
