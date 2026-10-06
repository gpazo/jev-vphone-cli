#!/bin/zsh
set -euo pipefail
task_root=${0:a:h:h:h}
exec "$task_root/.venv/bin/python" "$task_root/tests/DecisionReplay/clef_fallback.py"
