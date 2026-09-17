#!/bin/zsh
# start_amfidont_for_vphone.sh — Start amfidont for the current vphone build.
#
# This is the README "Option 2" host workaround packaged for this repo:
# - uses the project path so amfidont covers binaries relevant for the project
# - starts amfidont in daemon mode so signed vphone-cli launches are allowlisted
# - spoofs signatures to be recognized as apple signed for patchless variant

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"

if ! command -v amfidont &>/dev/null; then
  echo "amfidont not found" >&2
  echo "Install it first: xcrun python3 -m pip install -U amfidont" >&2
  exit 1
fi

sudo xcrun amfidont daemon \
    --path "$PROJECT_ROOT" \
    --spoof-apple \
    >/dev/null 2>&1

echo "amfidont started"
