"""Local $5 Clef vision experiment limit; not an account-wide billing control.

Reserve before sending, never refund uncertain or failed requests. Published
65,536-token maximum costs <2 cents on Clef and <1 cent on Flash at the prices
checked 2026-10-03. Those rounded-up reservations are retained even when the
reported usage is lower. Separate observed estimates are informational only.
"""
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import tempfile
import uuid

DEFAULT_LEDGER = Path(__file__).resolve().parents[2]/'research/artifacts/clef-vision-budget/ledger.json'
RESERVE_CENTS = {'clef': 2, 'clef-flash': 1}
NANODOLLARS_PER_TOKEN = {'clef': 240, 'clef-flash': 90}


class BudgetExhausted(ValueError):
    pass


class VisionBudget:
    def __init__(self, path=DEFAULT_LEDGER):
        self.path = Path(path)

    @contextmanager
    def locked(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.with_suffix('.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)

    def read(self):
        if not self.path.exists():
            return dict(version=1, limit_cents=500, price_checked='2026-10-03',
                        scope='Clef vision inference from this authorization; no subscription purchase.',
                        entries=[])
        value = json.loads(self.path.read_text())
        if value.get('version') != 1 or value.get('limit_cents') != 500:
            raise ValueError('Unexpected vision budget configuration; refusing to reset or increase it')
        for row in value['entries']:
            if row.get('reserved_cents') != RESERVE_CENTS.get(row.get('model')):
                raise ValueError('Invalid budget reservation')
        return value

    def write(self, value):
        with tempfile.NamedTemporaryFile(mode='w', dir=self.path.parent, delete=False) as output:
            temporary = Path(output.name)
            json.dump(value, output, indent=2, allow_nan=False)
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
        try:
            os.replace(temporary, self.path)
        finally:
            temporary.unlink(missing_ok=True)

    def reserve(self, model, request_sha256):
        amount = RESERVE_CENTS[model]
        with self.locked():
            value = self.read()
            used = sum(row['reserved_cents'] for row in value['entries'])
            if used + amount > value['limit_cents']:
                raise BudgetExhausted('The $5 local vision budget cannot cover another request')
            identifier = uuid.uuid4().hex
            value['entries'].append(dict(id=identifier, model=model, reserved_cents=amount,
                request_sha256=request_sha256, status='reserved_before_send',
                created_utc=datetime.now(timezone.utc).isoformat()))
            self.write(value)
        return identifier

    def finish(self, identifier, status, usage=None):
        with self.locked():
            value = self.read()
            row = next(row for row in value['entries'] if row['id'] == identifier)
            if row['status'] != 'reserved_before_send':
                raise ValueError('Budget request already settled')
            row['status'] = str(status)
            # Unknown usage keeps its full reservation. Never infer free usage
            # from a missing/failed response or refund a call after a crash.
            if isinstance(usage, dict):
                tokens = usage.get('input_tokens')
                if type(tokens) is int and 0 <= tokens <= 65536 and usage.get('output_tokens') == 0:
                    row['reported_input_tokens'] = tokens
                    row['estimated_nanodollars'] = tokens * NANODOLLARS_PER_TOKEN[row['model']]
            self.write(value)

    def summary(self):
        with self.locked():
            value = self.read()
        reserved = sum(row['reserved_cents'] for row in value['entries'])
        return dict(limit_usd=5, requests_reserved=len(value['entries']),
            conservatively_reserved_usd=reserved/100, remaining_reservable_usd=(500-reserved)/100,
            reported_usage_estimate_usd=sum(row.get('estimated_nanodollars', 0)
                for row in value['entries'])/1_000_000_000,
            requests_without_usage=sum('estimated_nanodollars' not in row for row in value['entries']))
