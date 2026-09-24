import unittest
from run import evaluate, valid_choice


def answer(choice, options):
    return dict(type='choice', choice=choice, confidence=.9,
                probabilities={v: 1 if v == choice else 0 for v in options})


class ScoringTests(unittest.TestCase):
    def test_wrong_binding_and_false_completion_fail_even_with_valid_output(self):
        request = {'questions': {'action': {'criteria': {'tap':'', 'finish':''}},
                    'tap_target': {'criteria': {'first':'', 'second':''}}}}
        case = dict(allowed={'tap':['second']}, complete=False)
        response = {'answers': {'action':answer('tap', ['tap','finish']),
                    'tap_target':answer('first', ['first','second']), 'done': {'noul':.01}}}
        self.assertFalse(evaluate(case,request,response)['decision_correct'])
        response['answers']['tap_target'] = answer('second', ['first','second'])
        self.assertTrue(evaluate(case,request,response)['decision_correct'])
        response['answers']['done']['noul'] = .95
        self.assertFalse(evaluate(case,request,response)['decision_correct'])

    def test_malformed_selected_distribution_is_not_a_pass(self):
        value = answer('second', ['first','second'])
        value['probabilities']['first'] = 1
        self.assertFalse(valid_choice(value,['first','second']))
        value = answer('unknown',['unknown'])
        self.assertFalse(valid_choice(value,['first','second']))

    def test_readiness_needs_correct_label_and_majority(self):
        request = {'questions': {'action': {'criteria': {'tap':''}},
            'tap_target': {'criteria': {'save':''}},
            'readiness_save': {'criteria': {'ready':'', 'mismatch':''}}}}
        case = dict(allowed={'tap':['save']},complete=False,readiness={'readiness_save':'ready'})
        response = {'answers': {'action':answer('tap',['tap']), 'tap_target':answer('save',['save']),
                    'readiness_save':answer('ready',['ready','mismatch'])}}
        self.assertTrue(evaluate(case,request,response)['readiness_correct']['readiness_save'])
        response['answers']['readiness_save']['probabilities'] = {'ready':.5,'mismatch':.5}
        self.assertFalse(evaluate(case,request,response)['readiness_correct']['readiness_save'])


if __name__ == '__main__':
    unittest.main()
