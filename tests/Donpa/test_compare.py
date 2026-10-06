import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('donpa_compare', Path(__file__).with_name('compare.py'))
compare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compare)


class ComparisonTests(unittest.TestCase):
    def test_counts_native_inputs_separately_from_waits_and_provider_calls(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary)
            decisions = run / 'decisions'
            call = decisions / 'planner-call-example'
            call.mkdir(parents=True)
            metrics = dict(initial_cleared_percent=0, first_nonzero_cleared_percent=50,
                           max_cleared_percent=100, first_terminal_observation={'seconds': 4, 'outcome': 'won'},
                           acknowledged_actions_after_terminal=0)
            result = dict(game_metrics=metrics, game_outcome='won', agent_seconds=5,
                          audit_complete=True, stable_win_candidate=True,
                          events=[{'text': '→ 1 perform "Move right" [Board]'},
                                  {'text': '→ 2 wait for the screen to settle conf 0.9'},
                                  {'text': 'attempt 3 tap Retry'}])
            (run / 'result.json').write_text(json.dumps(result))
            (run / 'agent.log').write_text('timing step 1 Jev decision: 1000 ms\ntiming step 2 Jev decision: 500 ms\ntiming total Jev decision: 1500 ms\n')
            (decisions / 'planner-example-request.json').write_text('{}')
            (decisions / 'planner-example-response.json').write_text(json.dumps({'steps': [{}, {}]}))
            (decisions / 'planner-example-rejection.json').write_text('{}')
            (call / 'events.jsonl').write_text(json.dumps({'type': 'turn.completed', 'usage': {'input_tokens': 10}}) + '\n')
            (call / 'timing.json').write_text(json.dumps({'duration_ns': 1_000_000_000}))
            summary = compare.summarize(run)
            self.assertEqual(summary['native_inputs'], 1)
            self.assertEqual(summary['waits'], 1)
            self.assertEqual(summary['inputs'], {'Move right': 1})
            self.assertEqual(summary['decision_median_seconds'], .75)
            self.assertEqual(summary['decisions_under_one_second'], 1)
            self.assertEqual(summary['provider_seconds'], 1)
            self.assertEqual(summary['planner_usage'], {'input_tokens': 10})
            self.assertEqual(summary['multistep_plans'], 1)
            self.assertEqual(summary['planned_steps'], 2)
            self.assertEqual(summary['contract_rejections'], 1)


if __name__ == '__main__':
    unittest.main()
