import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock

from PIL import Image

from clef_fallback import run
from vision_budget import VisionBudget


class ClefFallbackTests(unittest.TestCase):
    def test_budget_precedes_network_and_failures_never_retry(self):
        for scenario in ('success', 'quota', 'transport', 'malformed', 'missing_ledger', 'full_budget'):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                budget = VisionBudget(root/'ledger.json')
                if scenario != 'missing_ledger':
                    budget.write(budget.read())
                if scenario == 'full_budget':
                    budget.reserve('clef', 'old')
                    value = budget.read()
                    value['entries'] = [dict(value['entries'][0], id=str(i)) for i in range(250)]
                    budget.write(value)
                request = dict(model='clef', account_id='b'*32, simulator='108417FD-4FA3-4315-9587-0F4A0469E561',
                    state={'goal':'inspect','elements':[{'label':'Board','value':'Current cell'}]},
                    questions={'done':{'type':'noul','instructions':'Done?'}})
                factory = Mock()
                connection = factory.return_value
                response = connection.getresponse.return_value
                response.status = 429 if scenario == 'quota' else 200
                response.read.return_value = json.dumps(dict(success=True, errors=[], result=dict(model='clef',
                    answers={'done':{'type':'noul','noul':True if scenario=='malformed' else .1}},
                    usage={'input_tokens':10,'output_tokens':0}))).encode()
                def send(*args, **kwargs):
                    self.assertIn('/accounts/'+'b'*32+'/', args[1])
                    entry = budget.read()['entries'][-1]
                    self.assertEqual(entry['status'], 'reserved_before_send')
                    payload = json.loads(kwargs['body'])
                    self.assertEqual(payload['state'], request['state'])
                    self.assertEqual(payload['questions'], request['questions'])
                    self.assertEqual(len(payload['images']), 1)
                    self.assertNotIn('simulator', payload)
                    self.assertNotIn('account_id', payload)
                    if scenario == 'transport':
                        raise OSError('connection failed')
                connection.request.side_effect = send
                args = dict(budget=budget, capture=lambda p:Image.new('RGB',(60,120)).save(p),
                    connection_factory=factory, environment={'CLOUDFLARE_ACCOUNT_ID':'a'*32,
                        'CLOUDFLARE_API_TOKEN':'test-token', 'JEV_TRACE_DIR':str(root/'trace')})
                if scenario == 'success':
                    self.assertEqual(run(request, **args)['answers']['done']['noul'], .1)
                else:
                    with self.assertRaises(ValueError):
                        run(request, **args)
                self.assertEqual(connection.request.call_count, 0 if scenario in ('missing_ledger','full_budget') else 1)
                if scenario == 'missing_ledger':
                    self.assertFalse(budget.path.exists())
                elif scenario != 'full_budget':
                    self.assertEqual(budget.summary()['conservatively_reserved_usd'], .02)
