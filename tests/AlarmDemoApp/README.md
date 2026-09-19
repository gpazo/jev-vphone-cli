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

`simctl spawn <udid> defaults read com.jevdemo.alarm` does *not* resolve this
domain; read the plist directly.

## Status

The agent reliably opens the app, adds alarms and saves them — a run produced
five stored alarms. It does **not** reliably set a *specific* time. See
`docs/jev.md`, "Where OCR runs out".
