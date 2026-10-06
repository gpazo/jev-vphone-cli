"""Single budgeted Clef request for Jev's conditional vision fallback.

Input is the exact production question batch and AX state plus a resolved
Simulator UDID. Only captures screenshots; never operates the phone.
"""
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid

from compare_providers import connection_settings, decode_response, encode
from run import valid_choice
from vision_budget import VisionBudget
from vision_live import image_data


def validate_answers(result, questions):
    for head, question in questions.items():
        answer = result['answers'].get(head)
        if question['type'] == 'choice':
            valid = valid_choice(answer, question['criteria'])
        else:
            value = answer.get('noul') if isinstance(answer, dict) else None
            valid = (question['type'] == 'noul' and isinstance(answer, dict) and answer.get('type') == 'noul'
                     and type(value) in (int, float) and math.isfinite(value) and 0 <= value <= 1)
        if not valid:
            raise ValueError('Missing or invalid Clef answer for ' + head)


def run(request, *, budget=None, capture=None, connection_factory=http.client.HTTPSConnection, environment=None):
    environment = os.environ if environment is None else environment
    budget = VisionBudget() if budget is None else budget
    if not budget.path.exists():
        raise ValueError('The existing experiment ledger is required; refusing to create it')
    if request.get('model') != 'clef' or not isinstance(request.get('state'), dict) or not isinstance(request.get('questions'), dict):
        raise ValueError('Expected a Clef production state and question batch')
    simulator = request.get('simulator', '')
    if not re.fullmatch(r'[a-fA-F0-9-]{36}', simulator):
        raise ValueError('An explicit resolved Simulator UDID is required')
    connection_environment = dict(environment)
    if 'account_id' in request:
        connection_environment['CLOUDFLARE_ACCOUNT_ID'] = request['account_id']
    host, path, key = connection_settings('clef', connection_environment)
    trace = environment.get('JEV_TRACE_DIR')
    if not trace:
        raise ValueError('JEV_TRACE_DIR is required for the experiment audit')
    out = Path(trace)/('clef-vision-'+uuid.uuid4().hex)
    out.mkdir(parents=True)
    screenshot = out/'screen.png'
    if capture is None:
        subprocess.run(['/usr/bin/xcrun', 'simctl', 'io', simulator, 'screenshot', str(screenshot)],
                       check=True, timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    else:
        capture(screenshot)
    payload = {k:request[k] for k in ('model', 'state', 'questions')}
    payload['images'] = [image_data(screenshot)]
    data = encode(payload)
    (out/'request.json').write_bytes(data)
    reservation = budget.reserve('clef', hashlib.sha256(data).hexdigest())
    report = dict(reservation=reservation, request_sha256=hashlib.sha256(data).hexdigest(), simulator=simulator)
    (out/'report.json').write_text(json.dumps(report, indent=2)+'\n')
    connection = None
    started = time.monotonic()
    result = None
    try:
        connection = connection_factory(host, timeout=30)
        connection.request('POST', path, body=data, headers={'Content-Type':'application/json','Authorization':'Bearer '+key})
        response = connection.getresponse()
        report['http_status'] = response.status
        body = response.read()
        (out/'response.json').write_bytes(body.replace(key.encode(), b'<redacted>'))
        if response.status != 200:
            raise ValueError(f'HTTP {response.status}; no retry')
        result = decode_response('clef', body)
        validate_answers(result, payload['questions'])
        return result
    except Exception as error:
        report['error'] = (type(error).__name__ + ': ' + str(error)).replace(key, '<redacted>')
        raise ValueError(report['error']) from None
    finally:
        report['seconds'] = time.monotonic()-started
        budget.finish(reservation, report.get('http_status', 'transport_error'), (result or {}).get('usage'))
        if connection is not None:
            connection.close()
        report['budget'] = budget.summary()
        (out/'report.json').write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    try:
        print(json.dumps(run(json.load(sys.stdin)), allow_nan=False))
    except Exception as error:
        # Traceback and environment values are deliberately excluded.
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
