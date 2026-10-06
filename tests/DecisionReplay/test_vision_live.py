import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

from PIL import Image

from test_scoring import answer
from vision_live import STATUS, location_questions, main, position, terminal_or_uncertain, unchanged_target


class LiveVisionGuardTests(unittest.TestCase):
    def test_refinement_dry_run_freshness_and_post_tap_failure_bound_input(self):
        for scenario, expected_taps, expected_calls in [('dry',0,2),('ambiguous',0,2),('stale',0,2),
                                                       ('success',1,3),('verify_error',1,3)]:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as directory:
                out = Path(directory)/'trial'
                commands = []
                def fake_command(args):
                    commands.append(args)
                    if 'list' in args:
                        return json.dumps({'devices':{'runtime':[{'udid':'device','state':'Booted'}]}})
                    if 'getenv' in args:
                        return {'SIMULATOR_MAINSCREEN_SCALE':'3','SIMULATOR_MAINSCREEN_WIDTH':'1206',
                                'SIMULATOR_MAINSCREEN_HEIGHT':'2622'}[args[-1]]
                    if 'screenshot' in args:
                        color = 'black' if scenario=='stale' and 'fresh-before-tap' in args[-1] else 'white'
                        Image.new('RGB',(1206,2622),color).save(args[-1])
                    return ''
                def location(rows):
                    questions = location_questions(rows)
                    return dict(present={'type':'noul','noul':.99},
                        x=answer('4',questions['x']['criteria']), y=answer('5',questions['y']['criteria']))
                coarse = location(16)
                coarse['x']['confidence'] = .1  # Observation can refine; this never authorizes a tap.
                coarse['status'] = answer('playing',STATUS['criteria'])
                refined = location(8)
                if scenario=='ambiguous':
                    refined['x']['confidence'] = .59
                verification = dict(status=answer('won',STATUS['criteria']),
                    effect=answer('achieved',['achieved','unchanged','different','unknown']))
                responses = []
                for index, answers in enumerate([coarse,refined,verification]):
                    response = Mock()
                    response.status = 429 if scenario=='verify_error' and index==2 else 200
                    response.read.return_value = json.dumps(dict(success=True,errors=[],result=dict(answers=answers))).encode()
                    responses.append(response)
                args = ['vision_live.py','--simulator','device','--output',str(out),
                    '--target','a visible control','--goal','change the screen']
                if scenario!='dry':
                    args.append('--execute')
                with patch('sys.argv',args), patch('vision_live.command',side_effect=fake_command), \
                        patch('vision_live.connection_settings',return_value=('api.cloudflare.com','/test','test-token')), \
                        patch('vision_live.VisionBudget') as budget, \
                        patch('vision_live.http.client.HTTPSConnection') as connection, patch('builtins.print'):
                    budget.return_value.path = Path(directory)
                    budget.return_value.reserve.return_value = 'reservation'
                    budget.return_value.summary.return_value = {}
                    connection.return_value.getresponse.side_effect = responses
                    self.assertEqual(main(),0 if scenario in ('dry','success') else 1)
                    self.assertEqual(connection.return_value.request.call_count,expected_calls)
                    self.assertEqual(budget.return_value.finish.call_count,expected_calls)
                taps = [c for c in commands if 'tap' in c]
                self.assertEqual(len(taps),expected_taps)
                if taps:
                    self.assertIn('physical',taps[0])
                    self.assertNotIn('--label',taps[0])
                report = json.loads((out/'report.json').read_text())
                self.assertEqual(len(report['actions']),expected_taps)
                if scenario=='success':
                    self.assertEqual(report['post_action_stop'],'terminal_stop')

    def test_terminal_overrides_location_and_low_confidence(self):
        for state in ('won','lost'):
            response = {'answers':{'status':answer(state, STATUS['criteria'])}}
            response['answers']['status']['confidence'] = .1
            self.assertEqual(terminal_or_uncertain(response, False), 'terminal_stop')
            self.assertEqual(terminal_or_uncertain(response, True), 'uncertain_status')

    def test_ambiguous_or_malformed_location_never_produces_a_point(self):
        questions = location_questions(16)
        for field, bad in [('present',{'type':'noul','noul':True}), ('present',{'type':'noul','noul':.89}),
                           ('present',{'type':'noul','noul':float('nan')}), ('x',{'type':'choice'})]:
            response = {'answers':{'present':{'type':'noul','noul':.99},
                'x':answer('4',questions['x']['criteria']), 'y':answer('9',questions['y']['criteria'])}}
            response['answers'][field] = bad
            with self.subTest(field=field,bad=bad), self.assertRaises(ValueError):
                position(response, questions, (1206,2622))
        response = {'answers':{'present':{'type':'noul','noul':.99},
            'x':answer('4',questions['x']['criteria']), 'y':answer('9',questions['y']['criteria'])}}
        response['answers']['x']['confidence'] = .59
        with self.assertRaises(ValueError):
            position(response, questions, (1206,2622))
        # Low-confidence bins can guide observation, but cannot authorize a tap.
        self.assertEqual(len(position(response, questions, (1206,2622), observation_only=True)),2)

    def test_changed_target_or_display_dimensions_reject_freshness(self):
        original = Image.new('RGB',(100,200),'white')
        self.assertTrue(unchanged_target(original,original.copy(),(50,100),1))
        changed = original.copy()
        changed.paste('black',(35,85,65,115))
        self.assertFalse(unchanged_target(original,changed,(50,100),1))
        self.assertFalse(unchanged_target(original,Image.new('RGB',(200,100)),(50,100),1))

    def test_terminal_and_http_error_stop_before_any_native_input(self):
        for status in (200,429):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                out = Path(directory)/'trial'
                commands = []
                def fake_command(args):
                    commands.append(args)
                    if 'list' in args:
                        return json.dumps({'devices':{'runtime':[{'udid':'device','state':'Booted'}]}})
                    if 'getenv' in args:
                        return {'SIMULATOR_MAINSCREEN_SCALE':'3','SIMULATOR_MAINSCREEN_WIDTH':'1206',
                                'SIMULATOR_MAINSCREEN_HEIGHT':'2622'}[args[-1]]
                    if 'screenshot' in args:
                        Image.new('RGB',(1206,2622),'white').save(args[-1])
                    return ''
                result = dict(answers={'status':answer('won',STATUS['criteria'])}, model='clef-flash')
                args = ['vision_live.py','--simulator','device','--output',str(out),
                    '--target','a board cell','--goal','select the cell','--execute']
                with patch('sys.argv',args), patch('vision_live.command',side_effect=fake_command), \
                        patch('vision_live.connection_settings',return_value=('api.cloudflare.com','/test','test-token')), \
                        patch('vision_live.VisionBudget') as budget, \
                        patch('vision_live.http.client.HTTPSConnection') as connection, patch('builtins.print'):
                    budget.return_value.path = Path(directory)
                    budget.return_value.reserve.return_value = 'reservation'
                    budget.return_value.summary.return_value = {}
                    response = connection.return_value.getresponse.return_value
                    response.status = status
                    response.read.return_value = json.dumps(dict(success=True,errors=[],result=result)).encode()
                    self.assertEqual(main(),0 if status==200 else 1)
                    self.assertEqual(connection.return_value.request.call_count,1)
                    budget.return_value.finish.assert_called_once()
                report = json.loads((out/'report.json').read_text())
                self.assertEqual(report['actions'],[])
                self.assertFalse(any('tap' in command for command in commands))
                self.assertEqual(report['outcome'],'terminal_stop' if status==200 else 'stopped')


if __name__ == '__main__':
    unittest.main()
