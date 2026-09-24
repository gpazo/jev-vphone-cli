"""Record Jev creating and rescheduling one event in Apple's Calendar.

The controller sees only the natural-language goal. SQLite independently proves
both saved times belong to the same new event and preserves existing records.
"""
import argparse
from datetime import date, datetime, time as daytime, timedelta
import hashlib
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import sys
import threading
import time
from zoneinfo import ZoneInfo

from oracle import at_time, evaluate, snapshot

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests/SafariSearch'))
from record import Reader


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--date', type=date.fromisoformat, default=date.today()+timedelta(days=1))
    parser.add_argument('--title', default='Jev planning')
    parser.add_argument('--timezone', default='America/Los_Angeles')
    parser.add_argument('--controller', type=Path, default=ROOT/'.build/debug/vphone-cli')
    parser.add_argument('--max-steps', type=int, default=35)
    parser.add_argument('--validate-forms', action='store_true')
    parser.add_argument('--compact-requests', action='store_true')
    args = parser.parse_args()
    zone = ZoneInfo(args.timezone)
    initial_start = datetime.combine(args.date, daytime(9,30), zone)
    initial_end = datetime.combine(args.date, daytime(10,15), zone)
    final_start = datetime.combine(args.date, daytime(14), zone)
    final_end = datetime.combine(args.date, daytime(14,45), zone)
    goal = (f'In Calendar, create a new event titled {json.dumps(args.title)} on '
            f'{args.date.strftime("%B %d, %Y")} from 9:30 AM to 10:15 AM. '
            'Save it and return to the calendar. Find and reopen that same event, '
            'change its time to 2:00 PM–2:45 PM on the same date, save, and stop. '
            f'Use {args.timezone} time. Preserve all other events.')
    devices = json.loads(subprocess.check_output(['xcrun','simctl','list','devices','booted','--json']))
    ids = [d['udid'] for group in devices['devices'].values() for d in group if d['state']=='Booted']
    if len(ids) != 1:raise RuntimeError('Exactly one booted simulator is required')
    udid = ids[0]
    out = ROOT/'research/artifacts/jev-calendar'/time.strftime('%Y%m%d-%H%M%S');out.mkdir(parents=True)
    db = Path.home()/f'Library/Developer/CoreSimulator/Devices/{udid}/data/Library/Calendar/Calendar.sqlitedb'
    before = snapshot(db)
    if any(r['summary']==args.title for r in before.values()):
        raise RuntimeError('Use a new demo title; previous results are preserved')
    (out/'before-events.json').write_text(json.dumps(before, indent=2))
    subprocess.run(['xcrun','simctl','launch',udid,'com.apple.mobilecal'],check=True)
    reader = Reader(udid)
    agent = subprocess.Popen([str(args.controller.resolve()),'jev','--session','--simulator',udid,
                              '--verbose','--profile','--max-steps',str(args.max_steps)] + (['--validate-forms'] if args.validate_forms else [])
                             + (['--compact-requests'] if args.compact_requests else []),
                             stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,
                             env=dict(os.environ,NSUnbufferedIO='YES',JEV_TRACE_DIR=str(out/'decisions')))
    lines = queue.Queue()
    def collect():
        for line in agent.stdout:lines.put((time.monotonic(),line))
        lines.put((time.monotonic(),None))
    threading.Thread(target=collect,daemon=True).start()
    stop = threading.Event(); video = None; audit = None; milestones = []; errors = []; setup = []
    try:
        while True:
            _,line = lines.get(timeout=45)
            if line is None:raise RuntimeError('Controller exited: '+''.join(setup))
            setup.append(line)
            if 'ready     ' in line:break
        (out/'setup.log').write_text(''.join(setup))
        (out/'before.json').write_text(json.dumps(reader.tree()))
        video = subprocess.Popen(['xcrun','simctl','io',udid,'recordVideo','--codec=h264',str(out/'raw.mov')],
                                 stderr=subprocess.PIPE,text=True)
        for line in video.stderr:
            if 'Recording started' in line:break
        video_start = time.monotonic(); started = time.monotonic()
        def audit_saved():
            seen = set()
            try:
                while not stop.is_set():
                    records = snapshot(db)
                    for key, record in records.items():
                        if key in before:continue
                        for stage, begin, end in [('created',initial_start,initial_end),('rescheduled',final_start,final_end)]:
                            if (stage,key) not in seen and at_time(record,args.title,begin,end):
                                seen.add((stage,key))
                                milestones.append(dict(stage=stage,id=key,seconds=time.monotonic()-started,record=record))
                    stop.wait(.05)
            except Exception as error:errors.append(str(error))
        audit = threading.Thread(target=audit_saved,daemon=True);audit.start()
        agent.stdin.write(goal+'\n');agent.stdin.flush()
        events = []; success = False
        with (out/'agent.log').open('w') as log:
            while True:
                at,line = lines.get(timeout=60)
                if line is None:finish=at;break
                log.write(line);log.flush()
                if line.lstrip().startswith(('attempt   ','→','·','done      ','stopped   ','elapsed   ')):
                    events.append(dict(seconds=at-started,text=line.strip()))
                    print(f'{at-started:.3f}s {line.strip()}',flush=True)
                if line.lstrip().startswith('done      '):success=True
                if line.lstrip().startswith('elapsed   '):finish=at;break
        time.sleep(.3);stop.set();audit.join(timeout=5)
        after = snapshot(db)
        (out/'after-events.json').write_text(json.dumps(after,indent=2))
        try:(out/'after.json').write_text(json.dumps(reader.tree()))
        except Exception as error:errors.append(f'Final AX read: {error}')
        verdict = evaluate(before,after,milestones,args.title,final_start,final_end)
        result = dict(goal=goal, agent_seconds=finish-started, agent_start_video_seconds=started-video_start,
                      agent_claimed_success=success, verdict=verdict, milestones=milestones,
                      events=events, audit_errors=errors, setup=setup[-1].strip(), simulator=udid,
                      scoped_validation=os.environ.get('JEV_SCOPED_VALIDATION')=='1',
                      form_validation=args.validate_forms,
                      compact_requests=args.compact_requests,
                      controller_sha256=hashlib.sha256(args.controller.read_bytes()).hexdigest(),
                      oracle='Read-only Calendar SQLite; both saves must have the same new ID; never fed to Jev')
        (out/'result.json').write_text(json.dumps(result,indent=2));print(out,flush=True)
        print(json.dumps(result),flush=True)
        return 0 if verdict['passed'] and success and not errors else 1
    finally:
        stop.set()
        if audit:audit.join(timeout=5)
        if video and video.poll() is None:video.send_signal(signal.SIGINT);video.wait(timeout=15)
        agent.stdin.close()
        try:agent.wait(timeout=5)
        except subprocess.TimeoutExpired:agent.terminate();agent.wait(timeout=5)
        reader.close()


if __name__=='__main__':raise SystemExit(main())
