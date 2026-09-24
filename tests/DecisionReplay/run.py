"""Paired, read-only Jev decision replay. Never operates a phone.

Requests must first be exported through CompactRequestTests so the experiment
uses production Swift instructions. Expected decisions live in cases.json and
must be reviewed before running. API calls are explicit, separate from tests.
"""
import argparse
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import statistics
import time


def valid_choice(answer, options):
    if not isinstance(answer, dict) or answer.get('type') != 'choice':
        return False
    confidence = answer.get('confidence')
    probabilities = answer.get('probabilities', {})
    choice = answer.get('choice')
    number = lambda v: isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) and 0 <= v <= 1
    return (number(confidence) and set(probabilities) == set(options)
            and choice in options and all(number(p) for p in probabilities.values())
            and abs(sum(probabilities.values()) - 1) < .02
            and probabilities[choice] >= max(probabilities.values()) - 1e-6)


def evaluate(case, request, response):
    answers = response.get('answers', {})
    action_answer = answers.get('action', {})
    action = action_answer.get('choice')
    valid = valid_choice(action_answer, request['questions']['action']['criteria'])
    target_head = 'app' if action == 'open_app' else str(action) + '_target'
    target_answer = answers.get(target_head, {})
    target = target_answer.get('choice')
    if target_head in request['questions']:
        valid = valid and valid_choice(target_answer, request['questions'][target_head]['criteria'])
    allowed = case['allowed'].get(action)
    binding_correct = allowed is not None and (not allowed or target in allowed)
    done = answers.get('done', {}).get('noul', 0)
    completion_claim = done >= .8 or (action == 'finish' and done >= .5)
    readiness = {}
    for head, expected in case.get('readiness', {}).items():
        answer = answers.get(head, {})
        readiness[head] = (valid_choice(answer, request['questions'][head]['criteria'])
                           and answer.get('choice') == expected
                           and answer.get('probabilities', {}).get(expected, 0) > .5)
    return dict(valid_selected_answers=valid, action=action, target=target,
                binding_correct=binding_correct, completion_claim=completion_claim,
                decision_correct=valid and binding_correct and completion_claim == case['complete'],
                readiness_correct=readiness)


def summarize(runs):
    summary = {}
    for variant in ('original', 'compact'):
        group = [r for r in runs if r['variant'] == variant]
        good = [r for r in group if 'response' in r]
        tokens = [r['response'].get('usage', {}).get('input_tokens') for r in good]
        tokens = [v for v in tokens if isinstance(v, (int, float))]
        summary[variant] = dict(attempts=len(group), errors=len(group)-len(good),
            decisions_correct=sum(r['evaluation']['decision_correct'] for r in good),
            median_seconds=statistics.median(r['seconds'] for r in good) if good else None,
            median_input_tokens=statistics.median(tokens) if tokens else None,
            models=sorted({r['response'].get('model', 'unknown') for r in good}))
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--requests', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--runs', type=int, default=3)
    args = parser.parse_args()
    if not 1 <= args.runs <= 10:
        parser.error('runs must be 1–10')
    key = os.environ.get('TYPESAFE_API_KEY')
    if not key:
        parser.error('TYPESAFE_API_KEY is required')
    manifest = json.loads(Path(__file__).with_name('cases.json').read_text())
    requests = {}
    for case in manifest['cases']:
        for variant in ('original', 'compact'):
            requests[case['id'], variant] = json.loads((args.requests/f"{case['id']}-{variant}.json").read_text())
        original, compact = (requests[case['id'], v] for v in ('original', 'compact'))
        assert original['state'] == compact['state'], 'Replay cannot silently change evidence'
        assert original['model'] == compact['model']
        assert original['questions'].keys() == compact['questions'].keys()
        for head in original['questions']:
            a, b = original['questions'][head], compact['questions'][head]
            assert a['type'] == b['type'] and a.get('criteria') == b.get('criteria')
            if head not in ('action', 'app') and not head.endswith('_target'):
                assert a == b, 'Safety/readiness/completion questions must be identical'
    args.output.parent.mkdir(parents=True, exist_ok=True)
    runs = []
    connection = http.client.HTTPSConnection('api.typesafe.ai', timeout=30)
    try:
        for trial in range(args.runs):
            for index, case in enumerate(manifest['cases']):
                variants = ('original', 'compact') if (trial + index) % 2 == 0 else ('compact', 'original')
                for variant in variants:
                    payload = requests[case['id'], variant]
                    data = json.dumps(payload, separators=(',', ':')).encode()
                    result = dict(case=case['id'], trial=trial, variant=variant,
                                  request_bytes=len(data), request_sha256=hashlib.sha256(data).hexdigest())
                    started = time.monotonic()
                    try:
                        connection.request('POST', '/v1/systemone', body=data,
                            headers={'Content-Type':'application/json', 'Authorization':'Bearer '+key})
                        response = connection.getresponse()
                        body = response.read()
                        result['seconds'] = time.monotonic() - started
                        if response.status != 200:
                            raise RuntimeError(f'HTTP {response.status}')
                        result['response'] = json.loads(body)
                        result['evaluation'] = evaluate(case, payload, result['response'])
                    except Exception as error:
                        result['seconds'] = time.monotonic() - started
                        result['error'] = str(error)
                        connection.close()
                        connection = http.client.HTTPSConnection('api.typesafe.ai', timeout=30)
                    runs.append(result)
                    args.output.write_text(json.dumps(dict(manifest=manifest, runs=runs, summary=summarize(runs)), indent=2)+'\n')
                    print(json.dumps({k:v for k,v in result.items() if k not in ('response',)}), flush=True)
    finally:
        connection.close()
    print(json.dumps(summarize(runs), indent=2))
    return 1 if any('error' in r for r in runs) else 0


if __name__ == '__main__':
    raise SystemExit(main())
