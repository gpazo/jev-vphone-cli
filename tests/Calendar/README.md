# Calendar create-and-reschedule evaluation

Uses Apple's unmodified Calendar in the iOS Simulator. No Calendar navigation,
field names or saved-state rules are added to the controller.

Complete initial Calendar onboarding, use a writable local calendar, and start
on its day view. The recorder launches the app but does not create an account
or silently dismiss permission prompts. A test title must be new.

```sh
python3 tests/Calendar/record.py --date 2026-09-23 --title 'Jev planning'
# Experimental controller path:
JEV_SCOPED_VALIDATION=1 python3 tests/Calendar/record.py \
  --date 2026-09-24 --title 'Jev planning next'
python3 -m unittest discover -s tests/Calendar -p 'test_*.py'
```

The single goal requires saving 9:30–10:15 AM, reopening that event and saving
2:00–2:45 PM. A separate read-only SQLite connection polls for both saves with
the same new ID. The final check rejects skipped initial saves, duplicates,
wrong duration/date, all-day events and changes to the pre-existing records'
audited core fields. It checks title, times, time zones, calendar, description,
location reference, hidden status, entity type and UUID; it does not audit every
related Calendar database table. None of these facts are given to Jev.

The local iOS 26.5 schema stores events with `entity_type=2` and dates as seconds
since 2001-01-01 UTC. Those assumptions were checked against the native event's
displayed time and stored values, rather than inferred from EventKit enums.

Videos run at original speed. Readiness/startup is reported separately and
excluded from goal timing. The first baseline and prototype both failed:
they saved 9:30–10:30 AM, then searched while Calendar reported that indexing
was in progress. Those failed records are retained. The baseline's later
unsaved duplicate draft was discarded during the modal-guard test.

Results, limitations and next work: [scoped validation](../../research/jev_scoped_validation.md).
