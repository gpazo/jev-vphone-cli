"""Command/reporting regressions; no API key or simulator required.

Build with `make patcher_build`, then run `python3 tests/test_jev_commands.py`.
The fake phone is used only to check process exit status, not phone capability.
"""

import json
import os
import re
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / ".build/debug/vphone-cli"


class JevCommandTests(unittest.TestCase):
    def test_rejects_ocr_from_older_vm(self):
        with tempfile.TemporaryDirectory(prefix="jev-", dir="/tmp") as directory:
            path = str(Path(directory) / "phone.sock")
            requests = []
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(path)
                server.listen()
                server.settimeout(10)

                def serve():
                    for _ in range(2):  # installed apps, then observation
                        connection, _ = server.accept()
                        with connection, connection.makefile("rb") as reader:
                            requests.append(json.loads(reader.readline()))
                            connection.sendall(b'{"ok":true,"apps":[],"source":"ocr","elements":[]}\n')

                worker = threading.Thread(target=serve, daemon=True)
                worker.start()
                result = subprocess.run(
                    [str(BINARY), "jev", "open Settings", "--socket", path, "--baseline"],
                    capture_output=True, text=True, timeout=15,
                )
                worker.join(timeout=10)
                self.assertFalse(worker.is_alive())
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("OCR is disabled", result.stderr)
            self.assertTrue(requests[-1]["require_accessibility"])

    def test_rejects_nonpositive_step_budget(self):
        for steps in ("0", "-1"):
            with self.subTest(steps=steps):
                result = subprocess.run(
                    [str(BINARY), "jev", "open Settings", f"--max-steps={steps}"],
                    capture_output=True, text=True, timeout=15,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("--max-steps must be greater than zero", result.stderr)

    def test_budget_exhaustion_is_failure(self):
        # A short path stays within macOS's Unix-domain socket path limit.
        with tempfile.TemporaryDirectory(prefix="jev-", dir="/tmp") as directory:
            socket = Path(directory) / "phone.sock"
            phone = subprocess.Popen(
                [sys.executable, str(ROOT / "tests/jev_fake_phone.py"), str(socket)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            try:
                deadline = time.monotonic() + 5
                while not socket.exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue(socket.exists(), "fake phone failed to start")
                result = subprocess.run(
                    [str(BINARY), "jev", "open Settings", "--socket", str(socket),
                     "--baseline", "--max-steps", "1"],
                    capture_output=True, text=True, timeout=20,
                )
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("step budget of 1 exhausted", result.stdout)
            finally:
                phone.terminate()
                phone.wait(timeout=5)


class JevSessionTests(unittest.TestCase):
    def test_decompose_does_not_execute_a_helper_from_the_working_directory(self):
        with tempfile.TemporaryDirectory(prefix="jev-helper-", dir="/tmp") as directory:
            root = Path(directory)
            scripts = root / "scripts"
            scripts.mkdir()
            shadow = scripts / "jev_codex_planner.py"
            shadow.write_text('#!/bin/sh\nprintf shadow > "$PLANNER_MARKER"\nexit 1\n')
            shadow.chmod(0o755)
            codex = root / "fixture-codex"
            codex.write_text('#!/bin/sh\nprintf bundled > "$PLANNER_MARKER"\nexit 1\n')
            codex.chmod(0o755)
            marker = root / "used-helper"
            phone_path = root / "phone.sock"
            phone = subprocess.Popen(
                [sys.executable, str(ROOT / "tests/jev_fake_phone.py"), str(phone_path)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            try:
                deadline = time.monotonic() + 5
                while not phone_path.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(phone_path.exists())
                env = dict(os.environ, TYPESAFE_API_KEY="fixture-not-a-real-key",
                           JEV_CODEX_BINARY=str(codex), PLANNER_MARKER=str(marker))
                result = subprocess.run(
                    [str(BINARY), "jev", "open Settings", "--decompose", "--dry-run",
                     "--socket", str(phone_path), "--max-steps", "1"],
                    cwd=root, env=env, capture_output=True, text=True, timeout=20,
                )
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(marker.read_text(), "bundled")
                self.assertIn("Planner failed", result.stdout)
            finally:
                phone.terminate()
                phone.wait(timeout=5)

    def test_json_session_reuses_setup_and_isolates_failed_and_duplicate_goals(self):
        with tempfile.TemporaryDirectory(prefix="jev-session-", dir="/tmp") as directory:
            path = str(Path(directory) / "phone.sock")
            requests = []
            stopped = threading.Event()
            foreground = "Home"
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(path)
                server.listen()
                server.settimeout(0.1)

                def serve():
                    nonlocal foreground
                    while not stopped.is_set():
                        try:
                            connection, _ = server.accept()
                        except TimeoutError:
                            continue
                        with connection, connection.makefile("rb") as reader:
                            request = json.loads(reader.readline())
                            requests.append(request)
                            response = {"ok": True}
                            if request["t"] == "apps":
                                response["apps"] = [
                                    {"bundle_id": "example.settings", "name": "Settings"},
                                    {"bundle_id": "example.safari", "name": "Safari"},
                                ]
                            elif request["t"] == "observe":
                                response.update(source="accessibility", foreground=foreground,
                                    screen={"width": 400, "height": 800}, elements=[
                                        {"id": "settings", "role": "icon", "label": "Settings", "x": 50, "y": 100},
                                        {"id": "safari", "role": "icon", "label": "Safari", "x": 150, "y": 100},
                                    ])
                            elif request["t"] == "launch":
                                foreground = "Settings" if request["bundle"] == "example.settings" else "Safari"
                                if foreground == "Settings":
                                    response = {"ok": False, "error": "fixture acknowledgment lost"}
                            connection.sendall(json.dumps(response).encode() + b"\n")

                worker = threading.Thread(target=serve, daemon=True)
                worker.start()
                lines = [
                    {"id": "first", "goal": "open Settings"},
                    {"id": "first", "goal": "open Settings"},
                    "malformed request",
                    {"id": "second", "goal": "open Safari"},
                ]
                try:
                    result = subprocess.run(
                        [str(BINARY), "jev", "--session", "--session-json", "--baseline", "--verbose",
                         "--profile", "--max-steps", "1", "--socket", path],
                        input="\n".join(json.dumps(line) if isinstance(line, dict) else line for line in lines) + "\n",
                        capture_output=True, text=True, timeout=20,
                    )
                finally:
                    stopped.set()
                    worker.join(timeout=5)
                self.assertFalse(worker.is_alive())
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            events = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual([event["event"] for event in events], ["ready", "result", "rejected", "rejected", "result"])
            results = [event for event in events if event["event"] == "result"]
            self.assertEqual([event["id"] for event in results], ["first", "second"])
            self.assertEqual([event["goal"] for event in results], ["open Settings", "open Safari"])
            self.assertEqual([event["outcome"] for event in results], ["stopped", "exhausted"])
            self.assertTrue(all("completionAudit" not in event for event in results))
            self.assertEqual(sum(request["t"] == "apps" for request in requests), 1)
            self.assertEqual([request["bundle"] for request in requests if request["t"] == "launch"],
                             ["example.settings", "example.safari"])
            self.assertIn("  app       Settings", result.stderr)
            self.assertEqual(len(re.findall(r'"history"\s*:\s*\[\s*\]', result.stderr)), 2)

    def test_session_and_planner_flag_constraints(self):
        cases = [
            (["--session-json", "inspect"], "--session-json requires --session"),
            (["--session", "--session-json", "inspect"], "goals supplied as JSON lines"),
            (["inspect", "--decompose", "--planner", "/unused"], "Choose either --decompose or --planner"),
            (["inspect", "--decompose", "--baseline"], "cannot be combined with --baseline"),
        ]
        for arguments, message in cases:
            with self.subTest(arguments=arguments):
                result = subprocess.run([str(BINARY), "jev", *arguments], capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)


class JevDemoTests(unittest.TestCase):
    def run_demo(self, reading="1", agent_status=0, prompt=""):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            xcrun = root / "xcrun"
            xcrun.write_text('#!/bin/sh\nif [ "$2" = terminate ]; then exit 0; fi\nprintf "%s\\n" "$DEMO_READING"\n')
            sleep = root / "sleep"
            sleep.write_text("#!/bin/sh\nexit 0\n")
            agent = root / "agent"
            agent.write_text(
                f"#!{sys.executable}\n"
                "import json, os, sys\n"
                "print('ARGS=' + json.dumps(sys.argv[1:]))\n"
                "sys.exit(int(os.environ['DEMO_STATUS']))\n"
            )
            for executable in (xcrun, sleep, agent):
                executable.chmod(0o755)
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                       SIM="test-device", PROMPT=prompt, DEMO_READING=reading,
                       DEMO_STATUS=str(agent_status))
            return subprocess.run(
                ["zsh", str(ROOT / "scripts/jev_demo.sh"), str(agent), "--max-steps", "3"],
                env=env, capture_output=True, text=True, timeout=10,
            )

    def test_default_goal_requires_device_confirmation(self):
        result = self.run_demo(reading="0")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL: device does not confirm", result.stdout)

    def test_device_confirmation_and_agent_success(self):
        result = self.run_demo()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("VERIFIED: device reports", result.stdout)

    def test_reports_device_state_after_agent_failure(self):
        result = self.run_demo(agent_status=7)
        self.assertEqual(result.returncode, 7)
        self.assertIn("after (ground truth", result.stdout)
        self.assertIn("VERIFIED: device reports", result.stdout)
        self.assertIn("Agent exit status: 7", result.stdout)

    def test_unreadable_state_cannot_verify_success(self):
        result = self.run_demo(reading="")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("VERIFIED:", result.stdout)

    def test_custom_prompt_is_literal_and_not_claimed_as_verified(self):
        prompt = 'search for "hello"; $(echo unintended) `echo unintended`'
        result = self.run_demo(prompt=prompt)
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(next(line[5:] for line in result.stdout.splitlines() if line.startswith("ARGS=")))
        self.assertEqual(args, ["jev", prompt, "--simulator", "test-device", "--yes", "--max-steps", "3"])
        self.assertIn("does not verify this goal", result.stdout)
        self.assertNotIn("VERIFIED:", result.stdout)


if __name__ == "__main__":
    unittest.main()
