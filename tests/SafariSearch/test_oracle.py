"""Offline checks for the independent sequence verifier, not controller behavior."""
import unittest

from record import actions_started_after_load, result_links, verify_sequence


class SequenceTests(unittest.TestCase):
    query = 'sample query'
    ranked = [
        {'host': 'www.first.example', 'title': 'First article'},
        {'host': 'second.example', 'title': 'Second article'},
    ]

    def search(self):
        return {'document_title': self.query + ' - Google Search',
                'address': self.query, 'content_characters': 2000}

    def page(self, index):
        result = self.ranked[index]
        return {'document_title': result['title'], 'address': result['host'],
                'content_characters': 1000}

    def verify(self, timeline):
        return verify_sequence(timeline, self.ranked, self.query)[0]

    def test_requires_first_back_and_second_in_order(self):
        self.assertTrue(self.verify([self.search(), self.page(0), self.search(), self.page(1)]))
        self.assertFalse(self.verify([self.search(), self.page(0), self.page(1)]))
        self.assertFalse(self.verify([self.search(), self.page(1), self.search(), self.page(0)]))

    def test_address_change_with_old_search_body_is_not_a_visit(self):
        mixed = dict(self.search(), address=self.ranked[0]['host'])
        self.assertFalse(self.verify([self.search(), mixed, self.search(), self.page(1)]))

    def test_missing_content_or_wrong_host_is_not_a_visit(self):
        for invalid in [dict(self.page(0), content_characters=0),
                        dict(self.page(0), address='unrelated.example')]:
            self.assertFalse(self.verify([self.search(), invalid, self.search(), self.page(1)]))

    def test_back_must_return_to_same_query(self):
        other = dict(self.search(), document_title='other - Google Search', address='other')
        self.assertFalse(self.verify([self.search(), self.page(0), other, self.page(1)]))

    def test_ellipsized_heading_requires_substantial_prefix_host_and_content(self):
        ranked=[self.ranked[0],dict(self.ranked[1],title='Documentation for ...')]
        second=dict(self.page(1),document_title='Documentation for the full interface')
        sequence=[self.search(),self.page(0),self.search(),second]
        self.assertTrue(verify_sequence(sequence,ranked,self.query)[0])
        for bad in [dict(second,address='wrong.example'),dict(second,content_characters=0),
                    dict(second,document_title='Other documentation for the full interface')]:
            self.assertFalse(verify_sequence(sequence[:-1]+[bad],ranked,self.query)[0])
        ranked[1]['title']='Doc...'
        self.assertFalse(verify_sequence(sequence,ranked,self.query)[0])

    def test_visiting_second_then_leaving_is_not_terminal_success(self):
        self.assertFalse(self.verify([self.search(), self.page(0), self.search(), self.page(1), self.search()]))

    def test_navigation_acknowledgment_after_load_is_not_a_new_action(self):
        milestones=[{'seconds':n} for n in [1,2,3,4]]
        events=[{'seconds':3.8,'text':'attempt   5 tap Second'},
                {'seconds':4.1,'text':'→ 5 tap Second'}]
        self.assertEqual(actions_started_after_load(events,milestones),[])
        events += [{'seconds':4.2,'text':'attempt   6 scroll down'},
                   {'seconds':4.4,'text':'→ 6 scroll down'}]
        self.assertEqual(actions_started_after_load(events,milestones),[events[-1]])

    def test_ad_regions_are_excluded_from_organic_rank(self):
        p='XC_kAXXCAttribute'
        def result(title, host):
            return {p+'Label': f'Publisher https://{host} {title}', p+'Children':[
                {p+'Label':title,p+'AutomationType':42,p+'Value':'3'}]}
        tree={p+'Children':[{p+'Label':'Ads, region',p+'Children':[result('Paid', 'ads.example')]},
                            result('Organic', 'organic.example')]}
        self.assertEqual([r['host'] for r in result_links(tree)], ['organic.example'])


if __name__ == '__main__':
    unittest.main()
