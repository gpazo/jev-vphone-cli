import importlib.util
import hashlib
import tempfile
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('donpa_record',Path(__file__).with_name('record.py'))
recorder=importlib.util.module_from_spec(spec);spec.loader.exec_module(recorder)

class MetricsTests(unittest.TestCase):
    def frame(self,seconds,cleared,label='Board',value='Row 2, column 3: open, 1'):
        return {'seconds':seconds,'elements':[{'label':'Cleared','value':f'{cleared}%'},{'label':label,'value':value}]}

    def test_opening_cascade_is_not_counted_as_subsequent_progress(self):
        frames=[self.frame(0,0),self.frame(1,69),self.frame(2,69)]
        metrics=recorder.game_metrics(frames,[])
        self.assertEqual(metrics['additional_clearance_after_opening'],0)
        self.assertEqual(metrics['distinct_observed_cells'],1)
        frames.append(self.frame(3,71))
        self.assertEqual(recorder.game_metrics(frames,[])['additional_clearance_after_opening'],2)

    def test_restart_does_not_erase_observed_loss(self):
        frames=[self.frame(0,69),self.frame(1,69,'Boom — you stepped on a mine. Cleared 69%.',''),self.frame(3,0)]
        events=[{'seconds':2,'text':'→ 7 tap Retry'},{'seconds':3,'text':'stopped'}]
        metrics=recorder.game_metrics(frames,events)
        self.assertEqual(metrics['first_terminal_observation'],{'seconds':1,'outcome':'lost'})
        self.assertEqual(metrics['acknowledged_actions_after_terminal'],1)
        self.assertEqual(recorder.terminal_outcome(frames[-1]['elements']),'incomplete')

    def test_larger_opening_after_restart_is_not_progress(self):
        frames=[self.frame(0,0),self.frame(1,55),self.frame(2,0),self.frame(3,66)]
        metrics=recorder.game_metrics(frames,[])
        self.assertEqual(metrics['additional_clearance_after_opening'],0)
        self.assertEqual(len(metrics['observed_board_segments']),2)
        frames.append(self.frame(4,70))
        self.assertEqual(recorder.game_metrics(frames,[])['additional_clearance_after_opening'],4)

    def test_absent_audit_does_not_invent_clearance(self):
        self.assertIsNone(recorder.game_metrics([],[])['max_cleared_percent'])
        self.assertIsNone(recorder.game_metrics([],[])['additional_clearance_after_opening'])
        self.assertIsNone(recorder.game_metrics([],[])['first_terminal_observation'])

    def result_frame(self, seconds, label, automation_type=43, width=461, height=458):
        return {
            'seconds': seconds,
            'elements': [
                {'label': 'Cleared', 'value': '100%'},
                {'label': label, 'value': None, 'path': '/0/7',
                 'automation_type': automation_type,
                 'element_type': 'SwiftUI.AccessibilityNode',
                 'frame': {'X': 0, 'Y': 200, 'Width': width, 'Height': height},
                 'root_frame': {'X': 0, 'Y': 0, 'Width': 402, 'Height': 874}},
            ],
        }

    def test_invalid_result_shape_is_rejected(self):
        frame = self.result_frame(1, 'Minefield cleared', automation_type=0)
        self.assertIsNone(recorder.terminal_evidence(frame['elements']))
        self.assertFalse(recorder.game_metrics([frame], [])['stable_win_candidate'])

    def test_one_poll_terminal_is_only_a_candidate(self):
        frame = self.result_frame(1, 'Minefield cleared')
        metrics = recorder.game_metrics([frame], [])
        self.assertEqual(metrics['terminal_candidate']['outcome'], 'won')
        self.assertIsNone(metrics['stable_terminal_observation'])
        self.assertFalse(metrics['stable_win_candidate'])

    def test_stable_win_requires_two_shape_samples_and_no_actions_after(self):
        frames = [self.result_frame(1, 'Minefield cleared'),
                  self.result_frame(2, 'Minefield cleared')]
        metrics = recorder.game_metrics(frames, [])
        self.assertTrue(metrics['stable_win_candidate'])
        after = recorder.game_metrics(frames, [{'seconds': 3, 'text': '→ 1 tap Dig'}])
        self.assertFalse(after['stable_win_candidate'])
        self.assertEqual(after['acknowledged_actions_after_terminal'], 1)

    def test_wait_after_terminal_is_not_native_input(self):
        frames = [self.result_frame(1, 'Minefield cleared'), self.result_frame(2, 'Minefield cleared')]
        metrics = recorder.game_metrics(frames, [{'seconds': 3, 'text': '→ 1 wait for the screen to settle conf 0.90'}])
        self.assertTrue(metrics['stable_win_candidate'])
        self.assertEqual(metrics['acknowledged_actions_after_terminal'], 0)
        self.assertTrue(recorder.is_native_input({'text': '→ 2 tap "wait" conf 0.99'}))
        self.assertFalse(recorder.is_native_input({'text': 'attempt 2 tap Retry'}))

    def test_win_suffixes_from_result_panel_are_accepted(self):
        for label in ('Minefield cleared Pace 1.2.',
                      'New record! Minefield cleared in 0:12.3. Unlocked: XS'):
            frame = self.result_frame(1, label)
            self.assertEqual(recorder.terminal_evidence(frame['elements'])['outcome'], 'won')

    def test_exact_result_syntax_rejects_controller_like_labels(self):
        for label in ('Minefield cleared — done', 'Boom — you stepped on a mine',
                      'New record! Minefield cleared'):
            self.assertIsNone(recorder.terminal_evidence(
                self.result_frame(1, label)['elements']))

    def test_offscreen_and_nan_result_geometry_is_rejected(self):
        for x, width in ((-1000, 20), (float('nan'), 461)):
            frame = self.result_frame(1, 'Minefield cleared')
            frame['elements'][1]['frame']['X'] = x
            frame['elements'][1]['frame']['Width'] = width
            self.assertIsNone(recorder.terminal_evidence(frame['elements']))

    def test_retry_boundary_handles_higher_opening(self):
        frames = [self.frame(0, 0), self.frame(1, 55), self.frame(3, 70)]
        events = [{'seconds': 2, 'text': '→ 7 tap Retry'}]
        metrics = recorder.game_metrics(frames, events)
        self.assertEqual(metrics['observed_board_segments'][0]['maximum'], 55)
        self.assertEqual(metrics['observed_board_segments'][1]['opening'], 70)
        self.assertEqual(metrics['additional_clearance_after_opening'], 0)

    def test_actions_without_terminal_are_not_a_type_error(self):
        metrics = recorder.game_metrics([], [{'seconds': 1, 'text': '→ 1 tap Dig'}])
        self.assertEqual(metrics['acknowledged_actions_after_terminal'], 0)

    def test_planner_path_accepts_separate_and_equals_jev_args(self):
        self.assertEqual(recorder._planner_path(['--focused-requests', '--planner', '/tmp/p']), '/tmp/p')
        self.assertEqual(recorder._planner_path(['--planner=/tmp/p']), '/tmp/p')
        self.assertIsNone(recorder._planner_path(['--planner']))

    def test_file_sha256_hashes_only_explicit_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'planner'
            path.write_bytes(b'planner-test')
            expected = hashlib.sha256(b'planner-test').hexdigest()
            self.assertEqual(recorder._file_sha256(str(path)), expected)
            self.assertIsNone(recorder._file_sha256(str(path) + '.missing'))
            self.assertIsNone(recorder._file_sha256(None))

if __name__=='__main__':unittest.main()
