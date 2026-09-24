# Form validation experiments

`replay.py` submits recorded requests without controlling a phone. It compares
selection instructions with typed readiness judgments bound to one specific
candidate. Every request and response is retained without authentication headers.
The randomized order uses a fixed seed; latency includes Python HTTP/TLS overhead.
These are frozen-state probes, not whole-task success measurements.

```sh
python3 tests/FormValidation/replay.py path/to/request.json --commit e40 \
  --variants original focused readiness --runs 3 --output path/to/artifacts
```

The fixture candidate is explicitly supplied to avoid pretending that a parallel
question can see the action head's answer. The controller's opt-in
`--validate-forms` path instead asks about up to 24 bound candidates, consuming
only the selected tap's readiness. An out-of-batch selected candidate requires
one additional request. No commit-label heuristics or app-specific schemas are
used. The default path still uses one selection request without that gate.

Live evaluators:

```sh
python3 tests/Contacts/record.py --first Iris --last Vale \
  --company 'Jev form validation' --validate-forms
python3 tests/Calendar/record.py --title 'A unique new title' --validate-forms
```

Use a new identity/title and the evaluators' documented initial screen. They
audit app storage independently and never send those facts to Jev. Setup and
app launch are outside ready-session timing. Do not equate preventing a save
with completing a task. See [results and limitations](../../research/jev_form_validation.md).
