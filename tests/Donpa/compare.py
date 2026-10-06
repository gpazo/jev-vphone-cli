"""Compare recorded live runs without changing the simulator or interpreting a board."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import statistics


def summarize(directory):
    result = json.loads((directory / "result.json").read_text())
    log = (directory / "agent.log").read_text()
    metrics = result["game_metrics"]
    durations = [float(value) / 1000 for value in re.findall(r"timing step \d+ Jev decision: ([\d.]+) ms", log)]
    totals = {name: float(value) / 1000 for name, value in re.findall(r"timing total ([^:]+): ([\d.]+) ms", log)}
    inputs = Counter()
    waits = 0
    for event in result["events"]:
        if event["text"].startswith("→"):
            if re.match(r"^→\s*\d+\s+wait\b", event["text"]):
                waits += 1
                continue
            match = re.search(r'perform "([^"\n]+)"', event["text"])
            inputs[match.group(1) if match else "other"] += 1
    usage = Counter()
    provider_calls = 0
    for events in (directory / "decisions").glob("planner-call-*/events.jsonl"):
        provider_calls += 1
        for line in events.read_text().splitlines():
            event = json.loads(line)
            if event.get("type") == "turn.completed":
                usage.update(event.get("usage", {}))
    plans = [json.loads(path.read_text()) for path in (directory / "decisions").glob("planner-*-response.json")]
    provider_seconds = [json.loads(path.read_text())["duration_ns"] / 1e9
                        for path in (directory / "decisions").glob("planner-call-*/timing.json")]
    return {
        "run": directory.name,
        "outcome": result["game_outcome"],
        "seconds": result["agent_seconds"],
        "initial_percent": metrics["initial_cleared_percent"],
        "opening_percent": metrics["first_nonzero_cleared_percent"],
        "maximum_percent": metrics["max_cleared_percent"],
        "first_terminal": metrics["first_terminal_observation"],
        "post_terminal_inputs": metrics["acknowledged_actions_after_terminal"],
        "audit_complete": result["audit_complete"],
        "stable_win_candidate": result["stable_win_candidate"],
        "decision_count": len(durations),
        "decisions_under_one_second": sum(value < 1 for value in durations),
        "decision_median_seconds": statistics.median(durations) if durations else None,
        "timing_seconds": totals,
        "inputs": dict(inputs),
        "native_inputs": sum(inputs.values()),
        "waits": waits,
        "planned_steps": sum(len(plan.get("steps", [])) for plan in plans),
        "multistep_plans": sum(len(plan.get("steps", [])) > 1 for plan in plans),
        "contract_rejections": len(list((directory / "decisions").glob("planner-*-rejection.json"))),
        "planner_requests": len(list((directory / "decisions").glob("planner-*-request.json"))),
        "provider_calls": provider_calls,
        "provider_timed_calls": len(provider_seconds),
        "provider_seconds": sum(provider_seconds) if provider_seconds else None,
        "provider_median_seconds": statistics.median(provider_seconds) if provider_seconds else None,
        "planner_usage": dict(usage),
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runs", type=Path, nargs="+")
    args = parser.parse_args()
    print(json.dumps([summarize(run) for run in args.runs], indent=2))
