# Alarm demo app

The iOS Simulator ships no Clock app, so this stands in for one when
demonstrating the agent against a time picker.

It uses stock controls with no concessions to make it easier to drive — a
plain list, a `+` bar button, and a three-column wheel `DatePicker`, which is
what real Clock uses. An easier control would prove nothing.

## Build and install

```sh
xcrun -sdk iphonesimulator swiftc -parse-as-library \
    -target arm64-apple-ios17.0-simulator AlarmApp.swift -o AlarmDemo.app/AlarmDemo
cp Info.plist AlarmDemo.app/Info.plist
xcrun simctl install <udid> AlarmDemo.app
```

## Ground truth

Saved alarms land in the app's preferences, so the outcome can be checked
against the device rather than taken from the agent's own report:

```sh
plutil -p "$(xcrun simctl get_app_container <udid> com.jevdemo.alarm data)/Library/Preferences/com.jevdemo.alarm.plist"
```

The host plist can lag behind Save. For immediate verification the guest helper
reads the app's container-scoped defaults through cfprefsd. The recorder uses
a separate process for this audit, compares UUIDs, and preserves existing entries.

## Timed demo

Verified with the app unchanged: five live Jev decisions reached **1.664–1.951
seconds** from the home screen in a ready session. Startup takes about 2 seconds
separately. Other repeats exceeded 2 seconds; malformed answers fail safely.

Native accessibility exposes readable picker values (`9 o’clock`, `00 minutes`,
`AM`). Jev chooses a wheel and a literal target from the goal. Code adjusts and
verifies the wheel using native increment/decrement actions. No OCR is used.

From the repository root, after installing the app:

```sh
make setup_jev
make jev_session SIM=booted
# After ready, enter: Add a new alarm for 6:00 AM in the Alarms app and save it.

# Reproducible recording and independent verification:
python3 tests/AlarmDemoApp/record.py --simulator booted --runs 1
python3 tests/AlarmDemoApp/record.py --times 6AM 12PM 6PM
```

The recorder saves raw video, action timestamps, setup time, logs, before/after
records, and the independent audit duration in `research/artifacts/jev-alarm/`.
The ready-session timer includes the controller's UI-based completion check.
Saved-state facts are not supplied to Jev; the independent audit is reported
separately. Each successful run adds an alarm. The harness stops if either the
saved record is wrong or the controller fails to report completion, and records
both verdicts so these failures can be distinguished.

This app stores alarm entries; it does not schedule notifications. It is not
Apple Clock, which is absent from the installed simulator runtime.
