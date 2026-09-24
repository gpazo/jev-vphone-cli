# Safari search, first result, Back, second result

This is a live test of the general phone controller. It exercises literal text
entry, search/autocomplete, ranked links, occlusion, navigation, loading, history
and completion. No Safari or Google navigation plan is added to the controller.
Jev receives native accessibility text and the goal; OCR is never used.

After `make setup_jev`, `make patcher_build`, and booting an iOS simulator:

```sh
python3 tests/SafariSearch/record.py --query 'swift programming language'
python3 tests/SafariSearch/record.py --query 'wikipedia'
python3 -m unittest discover -s tests/SafariSearch -p 'test_*.py'
```

`TYPESAFE_API_KEY` must be set. The fixture opens example.com in Safari before
timing starts. The goal asks Jev to search Google, open the first organic result,
return to the same results using Back, and open the second organic result.
Ads, AI citations, navigation links and sitelinks are excluded. Browser history,
autocomplete, consent prompts, network speed and Google's live layout can vary;
these runs are exploratory evaluations, not a reproducible benchmark.

The independent read-only evaluator captures the first two result headings and
publisher hosts from Google's native accessibility tree. It checks this order:

1. The requested Google results page.
2. The first destination host, matching document title and nonempty body.
3. The original search page again.
4. The second destination host, matching document title and nonempty body.
5. The final observation is still that second destination.

This Google-specific oracle is deliberately outside the controller. It is
conservative and incomplete: title rewrites, redirects, or a new Google layout
can make it unable to verify a valid visit. Saved raw trees allow manual review.
An address change with the old search body is not accepted as a loaded page.
The oracle does not prove that every resource finished loading. History.db is
supplementary evidence because its writes can lag behind visible navigation.

Artifacts go to `research/artifacts/jev-safari/<timestamp>/`: original-speed
video, timestamped actions, raw audit trees, ranking evidence, setup timing and
separate `agent_claimed_success` / `verified_sequence` fields. Exit status is
zero only when both are true and the audit had no errors. Startup is excluded
from goal time and reported separately; audit collection runs concurrently and
can add device load. Audit timestamps are when a native read returns, not exact
browser paint times; confirmation can arrive after the controller stops.
New recordings include binary and recorder hashes.

The fixture now waits for a verified example.com screen before starting the
controller. After the independent audit observes all four navigation milestones,
it pauses its repeated full-tree reads. A new full-tree read after the controller
finishes checks the final state; action timestamps still detect late actions.
`audit_reads` records read durations and the final-check timestamp. This reduces
measurement interference, not production controller work. Use the same harness
when comparing controllers (`--controller /absolute/path/to/binary`). The timed
video shows the final audit separately from the controller's completion time.

See [the measured evaluation](../../research/jev_safari_evaluation.md) for
failures as well as the physically completed sequence. The newer
[progress/readiness review](../../research/jev_progress_review.md) covers the
subsequent fixes, passing runs, and remaining failures.

The [retired state-memory evaluation](../../research/jev_state_memory.md) records
unsuccessful iOS 26.5 live checks separately from earlier passing runs.

## Exact decision replay

The recorder enables `JEV_TRACE_DIR` for the controller. Its `decisions/` folder
contains exact request payloads and responses, without authentication headers.
They include the task and observed screen text. Replay one frozen decision with:

```sh
python3 tests/jev_replay.py path/to/UUID-request.json --runs 3 \
  --variants original without_history without_nearby \
  --output research/artifacts/jev-progress/replay.json
```

This calls Jev without operating the phone. It measures judgments on that fixed
state, not end-to-end success. `without_legacy_history` and `observed_history`
are diagnostic variants for older traces with contradictory histories; the
current controller derives history from its observed-outcome journal.

`--terminal-choice-completion` enables an experimental stopping rule and an
explicit `stop_unable` choice. It is not the default and is not established as
more reliable; keep the separate independent verdict when comparing it.


## Timed video and stopping audit

Use `python3 tests/SafariSearch/annotate.py <recording-directory>` with Pillow
and ffmpeg installed to render the original-speed capture with measured
milestones. The recorder now saves the video-to-goal offset for alignment.
Older recordings without that value use recording start as the overlay origin.

The evaluator separately reports `verified_sequence` and
`verified_stop_after_second_page`. It matches input acknowledgments to their
attempt times to detect extra actions begun after the second page loaded.
A correct route followed by an unnecessary scroll is not a clean pass; exit
status now requires the stop check as well as the route and completion claim.
See the [readiness evaluation](../../research/jev_document_readiness.md).
