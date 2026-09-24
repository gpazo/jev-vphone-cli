# Native text checks

Run `make setup_jev`, boot a simulator, then `python3 tests/NativeText/check.py`.
This modifies Safari’s address editor without submitting a navigation. It checks
Unicode and ASCII value readback through an independent accessibility connection,
then verifies that wrong-label, stale-value and non-editable targets reject text
replacement without changing the field. Results go to `research/artifacts/jev-native-text/`.

These are live mechanics checks without Jev. They do not establish support for
HTML forms whose native accessibility elements lack editable roles.
