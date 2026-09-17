#!/usr/bin/env python3
"""Fake phone for exercising the Jev agent loop without booting a VM.

Speaks the same Unix-socket protocol as VPhoneHostControl — one JSON line
in, one JSON line out — and models just enough of a phone to be steerable:
a few screens, a couple of toggles, and taps that actually change state.

Useful for tuning question wording and thresholds, where booting a real VM
per iteration would dominate the loop.

    python3 tests/jev_fake_phone.py /tmp/fake.sock          # screen: home|settings|wifi|safari|photos
    vphone-cli jev "turn on airplane mode" --socket /tmp/fake.sock -v
"""

from __future__ import annotations

import json
import os
import socket
import sys
import threading

SCREEN = {"width": 1290, "height": 2796}

APPS = [
    {"bundle_id": "com.apple.Preferences", "name": "Settings"},
    {"bundle_id": "com.apple.mobilesafari", "name": "Safari"},
    {"bundle_id": "com.apple.MobileSMS", "name": "Messages"},
    {"bundle_id": "com.apple.mobileslideshow", "name": "Photos"},
]


class FakePhone:
    """A tiny, deliberately literal phone."""

    def __init__(self) -> None:
        self.screen = "home"
        self.airplane_mode = False
        self.wifi = True
        self.search_focused = False
        self.search_query = None
        self.lock = threading.Lock()

    # -- observation ----------------------------------------------------

    def observe(self) -> dict:
        with self.lock:
            builder = getattr(self, f"_screen_{self.screen}")
            elements, foreground = builder()
        return {
            "foreground": foreground,
            "source": "accessibility",
            "screen": SCREEN,
            "elements": [
                {"id": f"e{i + 1}", **element} for i, element in enumerate(elements)
            ],
        }

    def _screen_home(self):
        return (
            [
                {"role": "icon", "label": "Settings", "x": 200, "y": 700},
                {"role": "icon", "label": "Safari", "x": 500, "y": 700},
                {"role": "icon", "label": "Messages", "x": 800, "y": 700},
                {"role": "icon", "label": "Photos", "x": 1100, "y": 700},
            ],
            "SpringBoard (com.apple.springboard)",
        )

    def _screen_settings(self):
        return (
            [
                {
                    "role": "switch",
                    "label": "Airplane Mode",
                    "value": "on" if self.airplane_mode else "off",
                    "x": 1100,
                    "y": 410,
                },
                {
                    # A navigation row, not a switch — the toggle lives one
                    # screen deeper, as it does on a real device.
                    "role": "cell",
                    "label": "Wi-Fi",
                    "value": "Home-5G" if self.wifi else "Off",
                    "x": 645,
                    "y": 530,
                },
                {"role": "cell", "label": "Bluetooth", "value": "On", "x": 645, "y": 650},
                {"role": "cell", "label": "General", "x": 645, "y": 900},
                {"role": "cell", "label": "Privacy & Security", "x": 645, "y": 1020},
            ],
            "Settings (com.apple.Preferences)",
        )

    def _screen_wifi(self):
        return (
            [
                {"role": "button", "label": "Settings", "x": 120, "y": 200},
                {
                    "role": "switch",
                    "label": "Wi-Fi",
                    "value": "on" if self.wifi else "off",
                    "x": 1100,
                    "y": 410,
                },
            ]
            + (
                [{"role": "cell", "label": "Home-5G", "value": "connected", "x": 645, "y": 560}]
                if self.wifi
                else []
            ),
            "Settings (com.apple.Preferences)",
        )

    def _screen_safari(self):
        if self.search_query:
            return (
                [
                    {"role": "textfield", "label": "Search or enter website",
                     "value": self.search_query, "x": 645, "y": 200},
                    {"role": "link", "label": f"Results for {self.search_query}",
                     "x": 645, "y": 500},
                    {"role": "link", "label": "Top story — climate talks open",
                     "x": 645, "y": 640},
                ],
                "Safari (com.apple.mobilesafari)",
            )
        return (
            [
                {
                    "role": "textfield",
                    "label": "Search or enter website",
                    "value": "focused, ready for input" if self.search_focused else "empty",
                    "x": 645,
                    "y": 200,
                },
                {"role": "button", "label": "Bookmarks", "x": 200, "y": 2600},
                {"role": "button", "label": "Tabs", "x": 1100, "y": 2600},
            ],
            "Safari (com.apple.mobilesafari)",
        )

    def _screen_photos(self):
        return (
            [
                {"role": "button", "label": "Select", "x": 1150, "y": 300},
                {"role": "button", "label": "Delete All Photos", "x": 645, "y": 2400},
                {
                    "role": "static_text",
                    "label": "This will permanently delete 4,812 photos",
                    "x": 645,
                    "y": 2500,
                },
            ],
            "Photos (com.apple.mobileslideshow)",
        )

    # -- actuation ------------------------------------------------------

    def tap(self, x: float, y: float) -> None:
        with self.lock:
            builder = getattr(self, f"_screen_{self.screen}")
            elements, _ = builder()
            hit = min(
                elements,
                key=lambda e: (e["x"] - x) ** 2 + (e["y"] - y) ** 2,
                default=None,
            )
            if hit is None:
                return
            label = hit["label"]

            if self.screen == "home":
                if label == "Settings":
                    self.screen = "settings"
                elif label == "Photos":
                    self.screen = "photos"
                elif label == "Safari":
                    self.screen = "safari"
            elif self.screen == "settings":
                if label == "Airplane Mode":
                    self.airplane_mode = not self.airplane_mode
                    # Airplane mode turns Wi-Fi off, as on a real device.
                    if self.airplane_mode:
                        self.wifi = False
                elif label == "Wi-Fi":
                    self.screen = "wifi"
            elif self.screen == "safari":
                if label == "Search or enter website":
                    self.search_focused = True
            elif self.screen == "wifi":
                if label == "Wi-Fi":
                    self.wifi = not self.wifi
                elif label == "Settings":
                    self.screen = "settings"
            print(f"  [phone] tapped {label!r} → {self.state_line()}", file=sys.stderr)

    def launch(self, bundle_id: str) -> None:
        with self.lock:
            self.screen = {
                "com.apple.Preferences": "settings",
                "com.apple.mobileslideshow": "photos",
                "com.apple.mobilesafari": "safari",
            }.get(bundle_id, "home")
            print(f"  [phone] launched {bundle_id} → {self.screen}", file=sys.stderr)

    def type_text(self, text: str) -> None:
        with self.lock:
            if self.screen == "safari" and self.search_focused:
                self.search_query = text
                self.search_focused = False
                print(f"  [phone] typed {text!r} → results", file=sys.stderr)
            else:
                # Typing with nothing focused goes nowhere, as on a real phone.
                print(f"  [phone] typed {text!r} into nothing (no field focused)",
                      file=sys.stderr)

    def press_home(self) -> None:
        with self.lock:
            self.screen = "home"
            print("  [phone] home", file=sys.stderr)

    def state_line(self) -> str:
        return (
            f"screen={self.screen} "
            f"airplane={'on' if self.airplane_mode else 'off'} "
            f"wifi={'on' if self.wifi else 'off'}"
        )


def handle(phone: FakePhone, conn: socket.socket) -> None:
    with conn:
        data = b""
        while not data.endswith(b"\n"):
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
        if not data:
            return

        try:
            command = json.loads(data.decode())
        except json.JSONDecodeError:
            conn.sendall(b'{"ok":false,"error":"invalid JSON"}\n')
            return

        kind = command.get("t")
        if kind == "observe":
            response = {"ok": True, **phone.observe()}
        elif kind == "apps":
            response = {"ok": True, "apps": APPS}
        elif kind == "tap":
            phone.tap(float(command["x"]), float(command["y"]))
            response = {"ok": True}
        elif kind == "launch":
            phone.launch(command["bundle"])
            response = {"ok": True}
        elif kind == "key":
            if command.get("name") == "home":
                phone.press_home()
            response = {"ok": True}
        elif kind == "type":
            phone.type_text(command.get("text", ""))
            response = {"ok": True}
        elif kind in ("swipe", "screenshot"):
            print(f"  [phone] {kind} (no-op)", file=sys.stderr)
            response = {"ok": True}
        else:
            response = {"ok": False, "error": f"unknown command: {kind}"}

        conn.sendall((json.dumps(response) + "\n").encode())


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/jev-fake-phone.sock"
    start = sys.argv[2] if len(sys.argv) > 2 else "home"

    phone = FakePhone()
    phone.screen = start

    if os.path.exists(path):
        os.unlink(path)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen(8)
    print(f"fake phone listening on {path} ({phone.state_line()})", file=sys.stderr)

    try:
        while True:
            conn, _ = server.accept()
            handle(phone, conn)
    except KeyboardInterrupt:
        print(f"\nfinal: {phone.state_line()}", file=sys.stderr)
    finally:
        server.close()
        if os.path.exists(path):
            os.unlink(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
