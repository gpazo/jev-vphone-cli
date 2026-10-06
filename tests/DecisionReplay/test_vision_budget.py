import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from compare_providers import main
from vision_budget import BudgetExhausted, VisionBudget


class VisionBudgetTests(unittest.TestCase):
    def test_reservation_survives_restart_and_failed_request(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'budget.json'
            budget = VisionBudget(path)
            pending = budget.reserve('clef', 'request-a')
            budget = VisionBudget(path)
            self.assertEqual(budget.summary()['conservatively_reserved_usd'], .02)
            budget.finish(pending, 429)
            other = budget.reserve('clef-flash', 'request-b')
            budget.finish(other, 200, {'input_tokens':3582, 'output_tokens':0})
            summary = budget.summary()
            self.assertEqual(summary['conservatively_reserved_usd'], .03)
            self.assertEqual(summary['requests_without_usage'], 1)
            self.assertAlmostEqual(summary['reported_usage_estimate_usd'], .00032238)
            with self.assertRaises(ValueError):
                budget.finish(other, 200)

    def test_budget_cannot_be_increased_or_refunded_by_unknown_usage(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'budget.json'
            budget = VisionBudget(path)
            identifier = budget.reserve('clef', 'x')
            budget.finish(identifier, 200, {'input_tokens':-1, 'output_tokens':0})
            self.assertEqual(budget.summary()['requests_without_usage'], 1)
            data = json.loads(path.read_text())
            data['limit_cents'] = 1000
            path.write_text(json.dumps(data))
            with self.assertRaises(ValueError):
                budget.reserve('clef', 'y')

    def test_full_budget_stops_before_network(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'budget.json'
            budget = VisionBudget(path)
            identifier = budget.reserve('clef', 'x')
            data = json.loads(path.read_text())
            data['entries'] = [dict(data['entries'][0], id=str(i)) for i in range(250)]
            path.write_text(json.dumps(data))
            with self.assertRaises(BudgetExhausted):
                budget.reserve('clef-flash', 'over-limit')
            argv = ['compare_providers.py', '--suite', 'vision', '--models', 'clef', '--runs', '1',
                    '--case', 'playing', '--image-encoding', 'jpeg-small',
                    '--budget-ledger', str(path), '--output', str(Path(folder)/'out.json')]
            environment = {'CLOUDFLARE_API_TOKEN':'test', 'CLOUDFLARE_ACCOUNT_ID':'a'*32}
            with patch('sys.argv', argv), patch.dict('os.environ', environment, clear=True), \
                    patch('compare_providers.http.client.HTTPSConnection') as connection, patch('builtins.print'):
                self.assertEqual(main(), 1)
                connection.return_value.request.assert_not_called()
            self.assertEqual(budget.summary()['conservatively_reserved_usd'], 5)

    def test_concurrent_calls_cannot_both_spend_last_cent(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'budget.json'
            budget = VisionBudget(path)
            budget.reserve('clef', 'x')
            data = json.loads(path.read_text())
            data['entries'] = [dict(data['entries'][0], id=str(i)) for i in range(249)]
            data['entries'].append(dict(data['entries'][0], id='last', model='clef-flash', reserved_cents=1))
            path.write_text(json.dumps(data))

            def try_reserve(index):
                try:
                    VisionBudget(path).reserve('clef-flash', str(index))
                    return True
                except BudgetExhausted:
                    return False

            with ThreadPoolExecutor(max_workers=2) as executor:
                self.assertEqual(sum(executor.map(try_reserve, range(2))), 1)
            self.assertEqual(budget.summary()['remaining_reservable_usd'], 0)

    def test_quota_probe_is_reserved_before_send_and_retained_after_failure(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'budget.json'
            output = Path(folder)/'out.json'
            argv = ['compare_providers.py', '--suite', 'vision', '--models', 'clef', '--runs', '1',
                    '--case', 'lost', '--image-encoding', 'jpeg-small',
                    '--budget-ledger', str(path), '--output', str(output)]
            environment = {'CLOUDFLARE_API_TOKEN':'test', 'CLOUDFLARE_ACCOUNT_ID':'a'*32}
            with patch('sys.argv', argv), patch.dict('os.environ', environment, clear=True), \
                    patch('compare_providers.http.client.HTTPSConnection') as connection, patch('builtins.print'):
                def sent(*args, **kwargs):
                    data = json.loads(path.read_text())
                    self.assertEqual(data['entries'][0]['status'], 'reserved_before_send')
                connection.return_value.request.side_effect = sent
                response = connection.return_value.getresponse.return_value
                response.status = 429
                response.read.return_value = b'{"errors":[{"code":4006,"message":"quota"}]}'
                self.assertEqual(main(), 1)
                self.assertEqual(connection.return_value.request.call_count, 1)
            self.assertEqual(VisionBudget(path).summary()['conservatively_reserved_usd'], .02)
            self.assertEqual(json.loads(output.read_text())['runs'][0]['provider_error_codes'], [4006])
