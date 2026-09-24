"""Calendar-specific, read-only outcome checks; never controller input."""
from datetime import datetime, timezone
from pathlib import Path
import sqlite3

APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc).timestamp()
FIELDS = ('summary', 'start_date', 'start_tz', 'end_date', 'end_tz', 'all_day',
          'calendar_id', 'description', 'location_id', 'hidden', 'entity_type', 'UUID')


def snapshot(path: Path):
    with sqlite3.connect(path.as_uri() + '?mode=ro', uri=True) as connection:
        return {row[0]: dict(zip(FIELDS, row[1:])) for row in connection.execute(
            'select ROWID,' + ','.join(FIELDS) + ' from CalendarItem')}


def at_time(record, title, start: datetime, end: datetime):
    return (record['summary'] == title and not record['all_day'] and not record['hidden']
            and record['entity_type'] == 2
            and abs((record['start_date'] or 0) + APPLE_EPOCH - start.timestamp()) < 1
            and abs((record['end_date'] or 0) + APPLE_EPOCH - end.timestamp()) < 1)


def evaluate(before, after, milestones, title, start, end):
    new = set(after) - set(before)
    preserved = all(after.get(key) == value for key, value in before.items())
    initial = next((m for m in milestones if m['stage'] == 'created'), None)
    final = next((m for m in milestones if m['stage'] == 'rescheduled'), None)
    route = bool(initial and final and initial['id'] == final['id']
                 and initial['seconds'] < final['seconds'])
    one_event = len(new) == 1
    correct = bool(one_event and route and new == {final['id']}
                   and at_time(after[final['id']], title, start, end))
    return dict(existing_events_preserved=preserved, same_event_rescheduled=route,
                exactly_one_new_event=bool(one_event), final_time_verified=correct,
                passed=preserved and correct)
