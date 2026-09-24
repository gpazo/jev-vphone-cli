#!/bin/zsh
set -euo pipefail

# Pin the upstream release and verify its published GitHub asset digest.
# Keep its frameworks beside the executable, as required by AXe's rpaths.
ROOT="${0:a:h:h}"
destination="$ROOT/.tools/axe"
version="1.8.0"
digest="7b76340b72e90d0f211bc7c4636f15009076eff07acef2f2b632b175debd8834"
if [[ -x "$destination/axe" ]] && [[ "$("$destination/axe" --version)" == "$version" ]]; then
    echo "AXe $version is ready at $destination/axe"
else
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
curl -fL --output "$staging/axe.tar.gz" \
    "https://github.com/cameroncooke/AXe/releases/download/v$version/AXe-macOS-v$version-universal.tar.gz"
echo "$digest  $staging/axe.tar.gz" | shasum -a 256 --check
mkdir -p "$staging/unpacked" "$destination"
tar -xzf "$staging/axe.tar.gz" -C "$staging/unpacked"
cp -R "$staging/unpacked/." "$destination/"
"$destination/axe" --version
fi

# The host translator exposes picker row indices, not their visible values.
# idb's guest reader supplies the full native tree and stays warm during a run.
bridge_digest="f59cadedbb05fe21c11522ee297cd8827b758136e27837a647267682cb2c80bb"
if [[ ! -x "$destination/SimulatorFrameworkBridge-iOS" ]]; then
    bridge_staging=$(mktemp -d)
    trap 'rm -rf "${staging:-}" "${bridge_staging:-}"' EXIT
    curl -fL --output "$bridge_staging/idb.tar.gz" \
        "https://github.com/facebook/idb/releases/download/v1.6.1/idb-companion.macos-arm64.tar.gz"
    echo "$bridge_digest  $bridge_staging/idb.tar.gz" | shasum -a 256 --check
    tar -xzf "$bridge_staging/idb.tar.gz" -C "$bridge_staging" ./Resources/SimulatorFrameworkBridge-iOS
    cp "$bridge_staging/Resources/SimulatorFrameworkBridge-iOS" "$destination/"
fi
# A read-only guest helper keeps CFPreferences warm between observations.
xcrun --sdk iphonesimulator clang -fobjc-arc -O2 \
    -arch "$(uname -m)" -mios-simulator-version-min=15.0 \
    -framework Foundation "$ROOT/scripts/jev/SimulatorPreferences.m" "$ROOT/scripts/jev/SimulatorActions.m" "$ROOT/scripts/jev/SimulatorTargets.m" \
    -o "$destination/JevSimulatorPreferences"
echo "Simulator accessibility, preferences and input are ready."
