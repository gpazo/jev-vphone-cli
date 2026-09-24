# Contacts evaluation

Run `make setup_jev` and `make patcher_build`, then:

```sh
python3 tests/Contacts/record.py --first Owen --last Park
```

For a paired comparison, `--controller /absolute/path/to/vphone-cli` selects a
saved executable; its SHA-256 is recorded in the result. Keep the starting screen
and evaluator unchanged across versions.

Requires a single booted simulator, Apple's Contacts app, and `TYPESAFE_API_KEY`.
The controller receives only the natural-language goal. It must navigate from
the current Contacts screen, create a **new** contact, fill three literal values,
and save it. This intentionally creates a demo record in the simulator.

A separate read-only SQLite connection compares every pre-existing contact ID
against the saved records. Renaming an old contact is a failure. The final audit
also checks that existing first/last/company values remain unchanged. These
facts are never supplied to the controller. Native before/after trees, exact
model requests, raw video, timings, and the result are saved under
`research/artifacts/jev-contacts/`.

The timer starts when the ready session receives the goal. App launch and session
startup are excluded. The save timestamp and controller completion timestamp are
reported separately. `annotate.py <artifact-directory>` renders an original-speed
video with those measurements; it requires Pillow and ffmpeg.

Run oracle regressions with:

```sh
python3 -m unittest discover -s tests/Contacts -p 'test_*.py'
```
