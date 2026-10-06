import json
import base64
import hashlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from compare_providers import connection_settings, decode_response, load_cases, load_vision_cases, main, payload_for, score, summarize
from test_scoring import answer


class ProviderReplayTests(unittest.TestCase):
    def test_provider_changes_only_model_selector(self):
        _, requests = load_cases()
        self.assertEqual(len(requests), 10)
        for original in requests.values():
            for model in ('jev', 'clef', 'clef-flash'):
                request = payload_for(original, model)
                self.assertEqual(request['state'], original['state'])
                self.assertEqual(request['questions'], original['questions'])

    def test_credentials_cannot_cross_providers(self):
        with self.assertRaises(ValueError):
            connection_settings('clef', {'TYPESAFE_API_KEY':'wrong', 'CLOUDFLARE_ACCOUNT_ID':'a'*32})
        with self.assertRaises(ValueError):
            connection_settings('clef', {'CLOUDFLARE_API_TOKEN':'key', 'CLOUDFLARE_ACCOUNT_ID':'../bad'})
        host, path, key = connection_settings('clef-flash',
            {'CLOUDFLARE_API_TOKEN':'cf-key', 'CLOUDFLARE_ACCOUNT_ID':'a'*32, 'TYPESAFE_API_KEY':'other'})
        self.assertEqual(host, 'api.cloudflare.com')
        self.assertTrue(path.endswith('/@cf/cloudflare/clef-flash'))
        self.assertEqual(key, 'cf-key')

    def test_cloudflare_envelope_requires_success_and_result(self):
        result = {'model':'clef', 'answers':{}}
        body = json.dumps({'success':True, 'errors':[], 'result':result})
        self.assertEqual(decode_response('clef', body), result)
        for value in [result, {'success':True, 'errors':[], 'result':None},
                      {'success':False, 'errors':[], 'result':result},
                      {'success':True, 'errors':[{'code':1}], 'result':result}]:
            with self.assertRaises(ValueError):
                decode_response('clef', json.dumps(value))

    def test_missing_or_invalid_safety_judgments_cannot_count_as_correct(self):
        request = {'questions': {'action': {'criteria': {'finish':'', 'wait':''}}}}
        case = {'allowed':{'finish':[]}, 'complete':True}
        response = {'answers': {'action':answer('finish', ['finish','wait']),
                    'done': {'type':'noul', 'noul':.99}}}
        self.assertFalse(score(case, request, response)['decision_correct'])
        for head in ('blocked', 'risky'):
            response['answers'][head] = {'type':'noul', 'noul':.01}
        self.assertTrue(score(case, request, response)['decision_correct'])
        response['answers']['risky']['noul'] = float('nan')
        self.assertFalse(score(case, request, response)['decision_correct'])

    def test_failures_remain_in_denominator(self):
        result = summarize([{'model':'clef', 'case':'x', 'error':'HTTP 403', 'seconds':1}], ['clef'])['clef']
        self.assertEqual(result['attempts'], 1)
        self.assertEqual(result['errors'], 1)
        self.assertEqual(result['decisions_correct'], 0)
        self.assertIsNone(result['median_seconds'])

    def test_auth_or_quota_failure_saves_partial_run_and_stops_requests(self):
        environment = {'TYPESAFE_API_KEY':'jev-key', 'CLOUDFLARE_API_TOKEN':'cf-key',
                       'CLOUDFLARE_ACCOUNT_ID':'a'*32}
        for status in (401, 403, 429):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                output = Path(directory)/'result.json'
                argv = ['compare_providers.py', '--models', 'clef', 'jev', '--runs', '1',
                        '--case', 'contacts-create', '--output', str(output)]
                with patch('sys.argv', argv), patch.dict('os.environ', environment, clear=True), \
                        patch('compare_providers.http.client.HTTPSConnection') as connection, \
                        patch('builtins.print'):
                    response = connection.return_value.getresponse.return_value
                    response.status = status
                    response.read.return_value = b'{}'
                    self.assertEqual(main(), 1)
                    self.assertEqual(connection.return_value.request.call_count, 1)
                saved = json.loads(output.read_text())
                self.assertFalse(saved['complete'])
                self.assertEqual(saved['planned_attempts'], 2)
                self.assertEqual(len(saved['runs']), 1)
                self.assertEqual(saved['runs'][0]['http_status'], status)
                self.assertEqual(saved['summary']['clef']['errors'], 1)
                self.assertEqual(saved['summary']['jev']['attempts'], 0)

    def test_vision_requests_do_not_contain_labels_or_accessibility(self):
        manifest, requests = load_vision_cases()
        self.assertEqual(len(requests), 3)
        for case in manifest['cases']:
            request = requests[case['id']]
            self.assertEqual(set(request), {'model','state','questions','images'})
            self.assertEqual(request['state'], manifest['state'])
            self.assertTrue(request['images'][0].startswith('data:image/png;base64,'))
            self.assertNotIn('expected_choices', request)
            answers = {head: answer(expected, request['questions'][head]['criteria'])
                       for head, expected in case['expected_choices'].items()}
            self.assertTrue(score(case, request, {'answers':answers})['decision_correct'])
            answers['status'] = answer('unknown', request['questions']['status']['criteria'])
            self.assertFalse(score(case, request, {'answers':answers})['decision_correct'])

    def test_jpeg_transport_preserves_dimensions_questions_and_frozen_labels(self):
        from PIL import Image
        original_manifest, original = load_vision_cases()
        manifest, requests = load_vision_cases(image_encoding='jpeg')
        for before, case in zip(original_manifest['cases'], manifest['cases']):
            name = case['id']
            self.assertEqual(before['expected_choices'], case['expected_choices'])
            self.assertEqual(original[name]['questions'], requests[name]['questions'])
            self.assertEqual(original[name]['state'], requests[name]['state'])
            encoded = requests[name]['images'][0]
            self.assertTrue(encoded.startswith('data:image/jpeg;base64,'))
            png = base64.b64decode(original[name]['images'][0].split(',', 1)[1])
            jpeg = base64.b64decode(encoded.split(',', 1)[1])
            with Image.open(io.BytesIO(png)) as a, Image.open(io.BytesIO(jpeg)) as b:
                self.assertEqual(a.size, b.size)
            self.assertEqual(hashlib.sha256(jpeg).hexdigest(), case['transport_image_sha256'])
            self.assertLess(len(jpeg), 1_000_000)

    def test_small_jpeg_requests_fit_observed_transport_limit_without_changing_labels(self):
        from compare_providers import encode
        original, original_requests = load_vision_cases()
        manifest, requests = load_vision_cases(image_encoding='jpeg-small')
        for before, case in zip(original['cases'], manifest['cases']):
            request = requests[case['id']]
            self.assertEqual(before['expected_choices'], case['expected_choices'])
            self.assertEqual(original_requests[case['id']]['questions'], request['questions'])
            self.assertEqual(max(case['transport_dimensions']), 1280)
            self.assertLess(len(encode(request)), 250_000)


if __name__ == '__main__':
    unittest.main()
