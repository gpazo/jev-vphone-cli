from datetime import datetime, timezone
import unittest
from oracle import APPLE_EPOCH, evaluate


class CalendarOracleTests(unittest.TestCase):
    def test_rejects_skipped_creation_duplicate_and_other_edits(self):
        start = datetime(2026, 9, 23, 21, tzinfo=timezone.utc)
        end = datetime(2026, 9, 23, 21, 45, tzinfo=timezone.utc)
        record = dict(summary='Jev planning', start_date=start.timestamp()-APPLE_EPOCH,
                      end_date=end.timestamp()-APPLE_EPOCH, all_day=0, hidden=0, entity_type=2)
        old = dict(record, summary='Existing')
        before = {1:old}; after = {1:old, 2:record}
        route = [dict(stage='created', id=2, seconds=1), dict(stage='rescheduled', id=2, seconds=2)]
        def check(a, m):return evaluate(before, a, m, 'Jev planning', start, end)['passed']
        self.assertTrue(check(after, route))
        self.assertFalse(check(after, route[1:]))
        self.assertTrue(evaluate(before, after, route[1:], 'Jev planning', start, end)['exactly_one_new_event'])
        self.assertFalse(check(after | {3:record}, route))
        self.assertFalse(check({1:record, 2:record}, route))
        self.assertFalse(check(after, [route[0], dict(route[1], id=3)]))
        self.assertFalse(check({1:old, 2:dict(record, end_date=record['end_date']+3600)}, route))
        self.assertFalse(check({1:old, 2:dict(record, all_day=1)}, route))


if __name__ == '__main__':unittest.main()
