#!/bin/zsh
set -euo pipefail

# Keep device evidence even when the agent stops or exhausts its budget.
# PROMPT comes through the environment so quotes and shell syntax stay data.
binary="$1"
shift
: "${SIM:?Set SIM to a booted simulator UDID or booted}"
goal="${PROMPT:-turn on Bold Text in Accessibility settings}"

read_bold_text() {
    xcrun simctl spawn "$SIM" defaults read com.apple.Accessibility EnhancedTextLegibilityEnabled 2>/dev/null
}

echo "── before ─────────────────────────────────────────────"
before=$(read_bold_text) || before="unavailable or unset"
echo "  Bold Text: $before"
echo
echo "── agent ──────────────────────────────────────────────"
xcrun simctl terminate "$SIM" com.apple.Preferences >/dev/null 2>&1 || true
sleep 2
agent_status=0
"$binary" jev "$goal" --simulator "$SIM" --yes "$@" || agent_status=$?

echo "── after (ground truth from the device) ───────────────"
after=$(read_bold_text) || after="unavailable or unset"
echo "  Bold Text: $after"
echo "  Agent exit status: $agent_status"

# Only the default goal has a known assertion. Custom prompts still report
# the device reading, but require their own task-specific verification.
if [[ -z "${PROMPT:-}" ]]; then
    if [[ "$after" != "1" ]]; then
        echo "  FAIL: device does not confirm Bold Text is on."
        exit 1
    fi
    echo "  VERIFIED: device reports Bold Text is on."
else
    echo "  Custom goal: the Bold Text reading alone does not verify this goal."
fi
exit "$agent_status"
