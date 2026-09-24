"""Command/reporting regressions; no API key or simulator required.

Build with `make patcher_build`, then run `python3 tests/test_jev_commands.py`.
The fake phone is used only to check process exit status, not phone capability.
"""

import json
import os
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
