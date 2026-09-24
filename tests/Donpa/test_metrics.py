import importlib.util
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

if __name__=='__main__':unittest.main()
