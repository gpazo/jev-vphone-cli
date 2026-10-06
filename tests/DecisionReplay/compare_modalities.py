"""Read-only Clef comparison: production Jev state, screenshot, or both.

One frozen paired observation, identical questions, rotating arm order. This
diagnoses evidence use; it does not run the Jev policy or operate the phone.
Every request, including text-only arms, uses the existing vision budget.
"""
import argparse
import copy
import hashlib
import http.client
import json
import os
from pathlib import Path
import statistics
import time

from compare_providers import connection_settings, decode_response, encode
from run import valid_choice
from vision_budget import VisionBudget
from vision_live import image_data

MODES = ('text','vision','combined')


def payload_for_mode(state, image, questions, model, mode):
    if mode not in MODES:
        raise ValueError('Unknown evidence mode')
    # The production accessibility state is byte-for-byte equivalent under
    # canonical JSON in text/combined arms. Vision receives only the same goal.
    payload = dict(model=model, state=copy.deepcopy(state if mode!='vision' else {'goal':state['goal']}),
                   questions=copy.deepcopy(questions))
    if mode!='text':
        payload['images'] = [image]
    return payload


def evaluate(response, questions, expected):
    checks = {head:valid_choice(response['answers'].get(head),questions[head]['criteria'])
        and response['answers'][head]['choice']==choice for head,choice in expected.items()}
    status = response['answers'].get('status',{})
    confidence = status.get('confidence',0)
    probability = status.get('probabilities',{}).get(status.get('choice'),0)
    return dict(checks=checks, all_correct=all(checks.values()),
        status_gate_passed=checks.get('status',False) and min(confidence,probability)>=.60)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case',type=Path,required=True,help='Frozen manifest with paired files, hashes, questions and labels')
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--model',choices=('clef','clef-flash'),default='clef')
    parser.add_argument('--runs',type=int,default=3)
    args = parser.parse_args()
    if args.output.exists() or not 1<=args.runs<=3:
        parser.error('Use a new result file and 1–3 repeats')
    case = json.loads(args.case.read_text())
    state_path, image_path = (args.case.parent/case[k] for k in ('state','image'))
    for kind, path in [('state',state_path),('image',image_path)]:
        if hashlib.sha256(path.read_bytes()).hexdigest()!=case[kind+'_sha256']:
            parser.error('Frozen observation changed; review the pair and labels before sending')
    state = json.loads(state_path.read_text())
    image = image_data(image_path)
    questions = case['questions']
    if set(questions)!=set(case['expected']) or any(case['expected'][h] not in q['criteria'] for h,q in questions.items()):
        parser.error('Labels must match the frozen questions')
    host, path, key = connection_settings(args.model,os.environ)
    budget = VisionBudget()
    if not budget.path.exists():
        parser.error('The existing shared experiment ledger is required')
    report = dict(case=case,model=args.model,planned_requests=3*args.runs,runs=[],complete=False)
    args.output.parent.mkdir(parents=True,exist_ok=True)

    def save():
        report['budget'] = budget.summary()
        report['summary'] = {}
        for mode in MODES:
            rows = [r for r in report['runs'] if r['mode']==mode]
            good = [r for r in rows if 'evaluation' in r]
            report['summary'][mode] = dict(attempts=len(rows),errors=len(rows)-len(good),
                all_correct=sum(r['evaluation']['all_correct'] for r in good),
                status_gate_passed=sum(r['evaluation']['status_gate_passed'] for r in good),
                correct_by_question={h:sum(r['evaluation']['checks'][h] for r in good) for h in questions},
                median_seconds=statistics.median(r['seconds'] for r in good) if good else None,
                input_tokens=sum(r['response'].get('usage',{}).get('input_tokens',0) for r in good))
        temporary = args.output.with_suffix('.tmp')
        temporary.write_text(json.dumps(report,indent=2,allow_nan=False)+'\n')
        temporary.replace(args.output)

    for trial in range(args.runs):
        for mode in MODES[trial:]+MODES[:trial]:
            payload = payload_for_mode(state,image,questions,args.model,mode)
            data = encode(payload)
            row = dict(mode=mode,trial=trial,request_bytes=len(data),request_sha256=hashlib.sha256(data).hexdigest())
            try:
                reservation = budget.reserve(args.model,row['request_sha256'])
            except Exception:
                save()
                raise
            row['budget_reservation'] = reservation
            report['runs'].append(row)
            save()
            connection = http.client.HTTPSConnection(host,timeout=30)
            started = time.monotonic()
            try:
                connection.request('POST',path,body=data,headers={'Content-Type':'application/json','Authorization':'Bearer '+key})
                response = connection.getresponse()
                row['http_status'] = response.status
                body = response.read()
                if response.status!=200:
                    raise ValueError(f'HTTP {response.status}')
                row['response'] = decode_response(args.model,body)
                row['evaluation'] = evaluate(row['response'],questions,case['expected'])
            except Exception as error:
                row['error'] = f'{type(error).__name__}: {str(error).replace(key,"<redacted>")}'
            finally:
                row['seconds'] = time.monotonic()-started
                budget.finish(reservation,row.get('http_status','transport_error'),row.get('response',{}).get('usage'))
                connection.close()
                save()
            print(json.dumps({k:v for k,v in row.items() if k!='response'}),flush=True)
            if 'error' in row:
                print('Stopped after the first request failure; no retry.',flush=True)
                return 1
    report['complete'] = True
    save()
    print(json.dumps(report['summary'],indent=2))
    return 0


if __name__=='__main__':
    raise SystemExit(main())
