# Donpa Squad game evaluation

The existing [Donpa Squad](https://github.com/vlumi/donpa) game is built without
game-source changes. Reference commit: `162955f33769e30d3a2d19cece13e2abac001519`.
It is an MIT-licensed iOS Minesweeper game. The controller receives native
accessibility observations, including named actions; it receives no hidden
board, solver output, or saved-game data.

Build the original project using a matching installed simulator runtime:

```sh
git clone https://github.com/vlumi/donpa.git /tmp/jev-donpa
git -C /tmp/jev-donpa checkout 162955f33769e30d3a2d19cece13e2abac001519
cd /tmp/jev-donpa
make generate
xcodebuild -project Donpa.xcodeproj -scheme Donpa-iOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/jev-donpa-build CODE_SIGNING_ALLOWED=NO build
xcrun simctl install <udid> '/tmp/jev-donpa-build/Build/Products/Debug-iphonesimulator/Donpa Squad.app'
```

From the controller repository, run `make setup_jev` and `make patcher_build`,
then:

```sh
python3 tests/Donpa/record.py --simulator <udid>
# Requires Pillow and ffmpeg; pass the directory printed by the recorder.
python3 tests/Donpa/annotate.py research/artifacts/jev-donpa/<timestamp>
```

The recorder enables the experimental general `--custom-actions` capability.
Native action names become selectable `accessibilityaction` elements. Execution
revalidates the owning control's label/value, resolves the named action's
current native identifier, and rejects missing/duplicate names before input.
This uses the existing tap selection head, with named-action semantics made
explicit in the observation. No game-specific input sequence is implemented.

Recordings include controller/game provenance, exact decisions (no API key),
step timings, video, and a separate read-only accessibility audit. The recorder
does not treat a controller success claim as a game win. The independent audit
classifies the game's visible result panel and retains the raw evidence for
review. Random boards and game losses remain
valid evaluation outcomes; interrupted or budget-exhausted play is incomplete.

The Donpa board's own accessibility interface exposes one focused cell at a
time, with movement, dig/chord, and flag actions. It does not expose the entire
board as separate tiles. This tests sequential observation and memory as well
as input. Custom-action discovery is opt-in pending broader app/runtime tests.

The prompt includes the game's control instruction that movement selects a cell
before Dig/Flag can act. An unassisted first attempt repeatedly dug without a
selection. The recorded follow-up made 45 decisions in 22.992 seconds but did
not finish the game; its first opening cascade cleared 69%, with no subsequent
clearing. See [the evaluation](../../research/jev_game_evaluation.md) for all
attempts, evidence, and limitations.

The evaluator
reports clearance after each observed board’s first nonzero reading, distinct observed cells,
the first visible win/loss, and acknowledged inputs after it. These metrics stay
outside controller input. A drop in clearance starts a new observed board segment;
a larger opening after Retry does not count as further play. See [the retired state-memory evaluation](../../research/jev_state_memory.md).
