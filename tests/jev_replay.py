"""Replay one recorded Jev request without operating the phone.

This tests a frozen decision, not task success. The API key is read from the
environment and never included in output. No input is sent to any device.
"""
import argparse
import copy
import json
import os
from pathlib import Path
import re
import time
import urllib.request


def ablate(payload, variant):
    result = copy.deepcopy(payload)
    if variant == 'without_history':
        result['state'].pop('history', None)
        result['state'].pop('observedProgress', None)
        for question in result['questions'].values():
            criteria = question.get('criteria', {})
            if isinstance(criteria, dict):
                for key, value in criteria.items():
                    if isinstance(value, str):
                        criteria[key] = re.sub(r'; prior executions on this document: [^\n]*', '', value)
    elif variant == 'without_nearby':
        result['state'].pop('nearbyElements', None)
    elif variant == 'without_legacy_history':
        result['state']['history'] = []
    elif variant == 'observed_history':
        result['state']['history'] = [dict(action=o['action'], changedScreen=o.get('screenChanged'),
            fromDocument=o.get('sourceDocument'), toDocument=o.get('observedDocument'))
            for o in result['state'].get('observedProgress', {}).get('outcomes', [])]
    elif variant == 'without_state_memory':
        # Hold the recorded short history fixed: this ablates the added
        # transition evidence/rules, not the separate history compaction.
        result['state'].get('observedProgress', {}).pop('controlMemory', None)
        device = result['state'].get('device', {})
        device['constraints'] = [s for s in device.get('constraints', []) if '`controlMemory`' not in s]
        for question in result['questions'].values():
            criteria = question.get('criteria', {})
            if isinstance(criteria, dict):
                for key, value in criteria.items():
                    if isinstance(value, str):
                        criteria[key] = re.sub(r'; (?:no recorded execution from this state|executed \d+x from this state).*', '', value)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('request', type=Path)
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--variants', nargs='+', choices=['original', 'without_history', 'without_nearby', 'without_legacy_history', 'observed_history', 'without_state_memory'], default=['original'])
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.runs <= 10:
        parser.error('runs must be 1–10')
    key = os.environ.get('TYPESAFE_API_KEY')
    if not key:
        parser.error('TYPESAFE_API_KEY is required')
    original = json.loads(args.request.read_text())
    results = []
    for variant in args.variants:
        payload = ablate(original, variant)
        for trial in range(args.runs):
            request = urllib.request.Request('https://api.typesafe.ai/v1/systemone',
                data=json.dumps(payload).encode(),
                headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + key})
            started = time.monotonic()
            with urllib.request.urlopen(request, timeout=30) as response:
                answer = json.load(response)
            result = {'variant': variant, 'trial': trial, 'seconds': time.monotonic() - started,
                      'response': answer}
            results.append(result)
            print(json.dumps({'variant': variant, 'trial': trial,
                              'action': answer['answers'].get('action'),
                              'done': answer['answers'].get('done')}), flush=True)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps({'source_request': str(args.request.resolve()), 'runs': results}, indent=2))


if __name__ == '__main__':
    main()
