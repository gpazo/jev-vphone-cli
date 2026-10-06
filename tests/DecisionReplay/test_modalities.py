import unittest

from compare_modalities import payload_for_mode


class EvidenceIsolationTests(unittest.TestCase):
    def test_vision_arm_cannot_leak_accessibility_and_combined_preserves_exact_state(self):
        state = {'goal':'win the game','elements':[{'id':'e7','label':'Cleared','value':'100%'}],
                 'history':[], 'observedProgress':{'outcomes':[]}, 'nearbyElements':[{'label':'private native label'}]}
        questions = {'status':{'type':'choice','criteria':{'won':'complete','unknown':'uncertain'}}}
        text = payload_for_mode(state,'image',questions,'clef','text')
        vision = payload_for_mode(state,'image',questions,'clef','vision')
        combined = payload_for_mode(state,'image',questions,'clef','combined')
        self.assertEqual(vision['state'],{'goal':'win the game'})
        self.assertNotIn('images',text)
        self.assertEqual(vision['images'],combined['images'])
        self.assertEqual(text['state'],state)
        self.assertEqual(combined['state'],state)
        self.assertEqual(text['questions'],vision['questions'])
        self.assertEqual(combined['questions'],vision['questions'])
        combined['state']['elements'].clear()
        self.assertEqual(len(state['elements']),1)
        self.assertEqual(len(text['state']['elements']),1)


if __name__=='__main__':
    unittest.main()
