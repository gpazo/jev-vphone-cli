"""Compare Jev, Clef and Clef-flash on identical frozen decisions; no phone input.

The default suite measures selected-answer correctness. The vision suite checks
frozen screenshots separately. Neither measures whole-task success.
Expected labels are never sent to either provider. Each call is saved, including
failures, with alternating model order and no automatic inference retries.
"""
import argparse
import base64
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import re
import statistics
import time

from run import evaluate, valid_choice
from vision_budget import BudgetExhausted, DEFAULT_LEDGER, VisionBudget


MODELS = ('jev', 'clef', 'clef-flash')
ROOT = Path(__file__).resolve().parent


def connection_settings(model, environment):
    if model == 'jev':
        key = environment.get('TYPESAFE_API_KEY')
        if not key:
            raise ValueError('TYPESAFE_API_KEY is required for Jev')
        return 'api.typesafe.ai', '/v1/systemone', key
    if model not in MODELS:
        raise ValueError('Unknown model')
    account = environment.get('CLOUDFLARE_ACCOUNT_ID', '')
    if not re.fullmatch(r'[a-fA-F0-9]{32}', account):
        raise ValueError('CLOUDFLARE_ACCOUNT_ID must be a 32-character account ID')
    key = environment.get('CLOUDFLARE_API_TOKEN') or environment.get('CLOUDFLARE_AUTH_TOKEN')
    if not key:
        raise ValueError('CLOUDFLARE_API_TOKEN is required for Clef')
    return 'api.cloudflare.com', f'/client/v4/accounts/{account}/ai/run/@cf/cloudflare/{model}', key


def decode_response(model, body):
    def reject_constant(value):
        raise ValueError('Non-finite JSON number')
    value = json.loads(body, parse_constant=reject_constant)
    if not isinstance(value, dict):
        raise ValueError('Response is not an object')
    if model != 'jev':
        if value.get('success') is not True or value.get('errors') != []:
            raise ValueError('Cloudflare returned an unsuccessful envelope')
        value = value.get('result')
    if not isinstance(value, dict) or not isinstance(value.get('answers'), dict):
        raise ValueError('Missing decision result/answers')
    return value


def payload_for(source, model):
    # The model selector is the sole difference between the comparison arms.
    return dict(source, model='jev-latest' if model == 'jev' else model)


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def score(case, request, response):
    if 'expected_choices' in case:
        checks = {}
        for head, expected in case['expected_choices'].items():
            answer = response['answers'].get(head, {})
            checks[head] = (valid_choice(answer, request['questions'][head]['criteria'])
                            and answer.get('choice') == expected)
        return dict(decision_correct=all(checks.values()), vision_checks=checks,
            completion_claim=response['answers'].get('status', {}).get('choice') == 'won', readiness_correct={})
    evaluation = evaluate(case, request, response)
    judgments = {}
    for head in ('done', 'blocked', 'risky'):
        answer = response['answers'].get(head)
        value = answer.get('noul') if isinstance(answer, dict) else None
        valid = (isinstance(answer, dict) and answer.get('type') == 'noul'
                 and isinstance(value, (int, float)) and not isinstance(value, bool)
                 and math.isfinite(value) and 0 <= value <= 1)
        judgments[head] = value if valid else None
    evaluation['judgments'] = judgments
    evaluation['valid_judgments'] = all(v is not None for v in judgments.values())
    evaluation['decision_correct'] &= evaluation['valid_judgments']
    return evaluation


def summarize(runs, models):
    summary = {}
    for model in models:
        group = [r for r in runs if r['model'] == model]
        good = [r for r in group if 'evaluation' in r]
        seconds = sorted(r['seconds'] for r in good)
        tokens = [(r['response'].get('usage') or {}).get('input_tokens') for r in good]
        tokens = [n for n in tokens if isinstance(n, int) and n >= 0]
        cases = {}
        for row in group:
            counts = cases.setdefault(row['case'], dict(attempts=0, correct=0, errors=0))
            counts['attempts'] += 1
            counts['errors'] += 'error' in row
            counts['correct'] += row.get('evaluation', {}).get('decision_correct', False)
        summary[model] = dict(attempts=len(group), errors=len(group)-len(good),
            decisions_correct=sum(r['evaluation']['decision_correct'] for r in good),
            false_completion_claims=sum(r['evaluation']['completion_claim'] and not r['expected_complete'] for r in good),
            readiness_correct=sum(sum(r['evaluation']['readiness_correct'].values()) for r in good),
            readiness_judgments=sum(len(r['evaluation']['readiness_correct']) for r in good),
            median_seconds=statistics.median(seconds) if seconds else None,
            p95_seconds=seconds[math.ceil(.95*len(seconds))-1] if seconds else None,
            median_input_tokens=statistics.median(tokens) if tokens else None,
            total_reported_input_tokens=sum(tokens), usage_samples=len(tokens),
            returned_models=sorted({r['response'].get('model', 'unknown') for r in good}),
            cases=cases)
    return summary


def load_cases(case_ids=None):
    manifest = json.loads((ROOT/'cases.json').read_text())
    cases = manifest['cases']
    if case_ids:
        unknown = set(case_ids) - {c['id'] for c in cases}
        if unknown:
            raise ValueError(f'Unknown cases: {sorted(unknown)}')
        cases = [c for c in cases if c['id'] in case_ids]
    requests = {c['id']: json.loads((ROOT/'fixtures'/f"{c['id']}.json").read_text()) for c in cases}
    for case in cases:
        request = requests[case['id']]
        assert set(request) == {'model', 'state', 'questions'}
        for operation, targets in case['allowed'].items():
            assert operation in request['questions']['action']['criteria']
            head = 'app' if operation == 'open_app' else operation+'_target'
            assert not targets or set(targets) <= set(request['questions'][head]['criteria'])
    return dict(manifest, cases=cases), requests


def load_vision_cases(case_ids=None, image_encoding='png'):
    manifest = json.loads((ROOT/'vision-cases.json').read_text())
    if case_ids:
        if set(case_ids) - {c['id'] for c in manifest['cases']}:
            raise ValueError('Unknown vision case')
        manifest['cases'] = [c for c in manifest['cases'] if c['id'] in case_ids]
    requests = {}
    for case in manifest['cases']:
        image = (ROOT/case['image']).read_bytes()
        if hashlib.sha256(image).hexdigest() != case['image_sha256']:
            raise ValueError('Vision fixture changed; review its labels before replay')
        content_type = 'image/png'
        if image_encoding in ('jpeg', 'jpeg-small'):
            # Explicit transport arms keep the full frame and frozen labels.
            # jpeg-small scales uniformly; neither arm crops or annotates.
            import io
            from PIL import Image
            with Image.open(io.BytesIO(image)) as source:
                buffer = io.BytesIO()
                source = source.convert('RGB')
                if image_encoding == 'jpeg-small':
                    source.thumbnail((1280, 1280), Image.Resampling.LANCZOS)
                source.save(buffer, format='JPEG', quality=80 if image_encoding == 'jpeg-small' else 90, optimize=True)
                image = buffer.getvalue()
                case['transport_dimensions'] = list(source.size)
            content_type = 'image/jpeg'
        case['transport_encoding'] = {'png':'original-png', 'jpeg':'jpeg-quality-90',
            'jpeg-small':'jpeg-quality-80-max-edge-1280'}[image_encoding]
        case['transport_image_sha256'] = hashlib.sha256(image).hexdigest()
        case['transport_image_bytes'] = len(image)
        questions = dict(manifest['questions'])
        if case['id'] == 'playing':
            questions.update(manifest['board_questions'])
        requests[case['id']] = dict(model='clef', state=manifest['state'], questions=questions,
            images=['data:'+content_type+';base64,'+base64.b64encode(image).decode()])
        for head, choice in case['expected_choices'].items():
            assert choice in questions[head]['criteria']
    return manifest, requests


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--models', nargs='+', choices=MODELS, default=list(MODELS))
    parser.add_argument('--suite', choices=('decisions', 'vision'), default='decisions')
    parser.add_argument('--image-encoding', choices=('png', 'jpeg', 'jpeg-small'), default='png',
                        help='Vision: original PNG, JPEG quality 90, or JPEG quality 80 with max edge 1280')
    parser.add_argument('--budget-ledger', type=Path, default=DEFAULT_LEDGER,
                        help='Persistent $5 ledger required by vision runs; reuse it across experiments')
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--case', action='append', dest='cases')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--validate-only', action='store_true', help='Check fixtures without credentials or API calls')
    args = parser.parse_args()
    if not 1 <= args.runs <= 10 or len(set(args.models)) != len(args.models):
        parser.error('Use 1–10 runs and distinct models')
    if args.suite == 'vision' and 'jev' in args.models:
        parser.error('Vision requires --models clef clef-flash; Jev does not accept images')
    if args.suite != 'vision' and args.image_encoding != 'png':
        parser.error('--image-encoding is only supported by the vision suite')
    try:
        manifest, requests = (load_vision_cases(args.cases, args.image_encoding)
                              if args.suite == 'vision' else load_cases(args.cases))
        if args.validate_only:
            print(f"Validated {len(requests)} frozen cases; no requests sent.")
            return 0
        # Check every credential before billing even the first arm.
        settings = {m: connection_settings(m, os.environ) for m in args.models}
    except ValueError as error:
        parser.error(str(error))
    if args.output is None or args.output.exists():
        parser.error('--output must name a new results file')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    connections = {m: http.client.HTTPSConnection(s[0], timeout=30) for m, s in settings.items()}
    budget = VisionBudget(args.budget_ledger) if args.suite == 'vision' else None
    used_connections = set()
    runs = []
    planned = args.runs * len(manifest['cases']) * len(args.models)

    def save():
        recorded_requests = {}
        for name, request in requests.items():
            recorded_requests[name] = {k:v for k,v in request.items() if k != 'images'}
        document = dict(scope=manifest['scope'], suite=args.suite, manifest=manifest, requests=recorded_requests,
            image_note='Image bytes omitted from this report; frozen file paths and hashes are in the manifest.',
            planned_attempts=planned, complete=len(runs) == planned,
            runs=runs, summary=summarize(runs, args.models))
        if budget:
            document['budget'] = budget.summary()
        temporary = args.output.with_suffix(args.output.suffix+'.tmp')
        temporary.write_text(json.dumps(document, indent=2, allow_nan=False)+'\n')
        temporary.replace(args.output)

    try:
        for trial in range(args.runs):
            for index, case in enumerate(manifest['cases']):
                shift = (trial + index) % len(args.models)
                order = args.models[shift:] + args.models[:shift]
                for model in order:
                    payload = payload_for(requests[case['id']], model)
                    data = encode(payload)
                    evidence = {k:v for k,v in payload.items() if k != 'model'}
                    row = dict(case=case['id'], trial=trial, model=model, expected_complete=case['complete'],
                        request_bytes=len(data),
                        request_sha256=hashlib.sha256(data).hexdigest(),
                        evidence_sha256=hashlib.sha256(encode(evidence)).hexdigest(),
                        new_connection=model not in used_connections)
                    started = time.monotonic()
                    stop_status = None
                    if budget:
                        try:
                            reservation = budget.reserve(model, row['request_sha256'])
                        except BudgetExhausted as error:
                            save()
                            print(str(error), flush=True)
                            return 1
                        row['budget_reservation'] = reservation
                    try:
                        host, path, key = settings[model]
                        connections[model].request('POST', path, body=data,
                            headers={'Content-Type':'application/json', 'Authorization':'Bearer '+key})
                        response = connections[model].getresponse()
                        body = response.read()
                        row['seconds'] = time.monotonic()-started
                        used_connections.add(model)
                        row['http_status'] = response.status
                        if response.status in (401, 403, 429):
                            stop_status = response.status
                        if response.status != 200:
                            # Retain numeric provider error codes without logging
                            # credentials, account IDs, or arbitrary response text.
                            try:
                                row['provider_error_codes'] = [e['code'] for e in json.loads(body).get('errors', [])
                                    if isinstance(e, dict) and type(e.get('code')) is int]
                            except (ValueError, AttributeError, TypeError):
                                pass
                            raise ValueError(f'HTTP {response.status}')
                        decoded = decode_response(model, body)
                        row['evaluation'] = score(case, payload, decoded)
                        row['response'] = decoded
                    except Exception as error:
                        row['seconds'] = time.monotonic()-started
                        # No headers, credentials, account ID, or raw error body in logs.
                        detail = str(error).replace(settings[model][2], '<redacted>')
                        row['error'] = f'{type(error).__name__}: {detail}'
                        connections[model].close()
                        connections[model] = http.client.HTTPSConnection(settings[model][0], timeout=30)
                        used_connections.discard(model)
                    if budget:
                        budget.finish(reservation, row.get('http_status', 'transport_error'),
                                      row.get('response', {}).get('usage'))
                    runs.append(row)
                    save()
                    print(json.dumps({k:v for k,v in row.items() if k != 'response'}, allow_nan=False), flush=True)
                    if stop_status is not None:
                        reason = 'rate/quota limit' if stop_status == 429 else 'authentication failure'
                        print(f'Stopped after {reason} (HTTP {stop_status}); results are incomplete.', flush=True)
                        return 1
    finally:
        for connection in connections.values():
            connection.close()
    print(json.dumps(summarize(runs, args.models), indent=2))
    return int(any('error' in r for r in runs))


if __name__ == '__main__':
    raise SystemExit(main())
