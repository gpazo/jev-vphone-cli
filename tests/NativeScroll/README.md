# Native scroll mechanics benchmark

`python3 tests/NativeScroll/benchmark.py` runs six alternating native page-scroll
and six old HID drag trials against a static HTML fixture in Safari, then four
native scroll trials in Settings. It requires one booted simulator and the Jev
helpers. It makes **no Jev decisions** and is not an autonomous task benchmark.

Each trial stores independent before/after native trees. It measures command
acknowledgment and time until two consecutive native layouts agree after changing.
That is accessibility layout stability, not a guarantee that every display
animation has finished. A deliberately stale anchor must be rejected without
moving the screen.

The two input mechanisms have the same direction/reveal intent, not identical
travel distance: native input requests one page, whereas the old drag traverses
40% of the screen with 60 motion events. Settings uses its current pane; a pane
that cannot scroll will fail rather than be reported as success.
