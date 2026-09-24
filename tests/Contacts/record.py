"""Jev creates a contact in Apple's unmodified Contacts app.
The controller receives only a goal. A separate read-only SQLite connection
checks for a newly saved record; none of that evidence is fed to Jev.
"""
import hashlib
import argparse
import json
import os
from pathlib import Path
import queue
import signal
import sqlite3
import subprocess
import sys
import threading
import time

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tests/SafariSearch'))
from record import Reader

from oracle import contact_snapshot, verify_saved_contact

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--first',default='Mira')
    parser.add_argument('--last',default='Stone')
    parser.add_argument('--company',default='Jev demo')
    parser.add_argument('--validate-forms', action='store_true')
    parser.add_argument('--compact-requests', action='store_true')
    parser.add_argument('--controller',type=Path,default=ROOT/'.build/debug/vphone-cli',help='Controller executable for paired measurements')
    args=parser.parse_args()
    goal=f'In Contacts, create a new contact with first name {json.dumps(args.first)}, last name {json.dumps(args.last)}, and company {json.dumps(args.company)}. Save the contact and stop.'
    devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','booted','--json']))
    ids=[d['udid'] for group in devices['devices'].values() for d in group if d['state']=='Booted']
    if len(ids)!=1:raise RuntimeError('Exactly one booted simulator is required')
    udid=ids[0]
    out=ROOT/'research/artifacts/jev-contacts'/time.strftime('%Y%m%d-%H%M%S');out.mkdir(parents=True)
    db=Path.home()/f'Library/Developer/CoreSimulator/Devices/{udid}/data/Library/AddressBook/AddressBook.sqlitedb'
    def saved():
        with sqlite3.connect(db.as_uri()+'?mode=ro',uri=True) as c:
            return [dict(zip(['id','first','last','company'],row)) for row in c.execute(
                'select ROWID,First,Last,Organization from ABPerson where First=? and Last=? and Organization=?',(args.first,args.last,args.company))]
    # A renamed old contact is not a newly created contact. Compare against
    # every pre-existing ID, not merely records already matching this goal.
    before_contacts=contact_snapshot(db)
    baseline=set(before_contacts)
    subprocess.run(['xcrun','simctl','launch',udid,'com.apple.MobileAddressBook'],check=True)
    reader=Reader(udid)
    agent=subprocess.Popen([str(args.controller.resolve()),'jev','--session','--simulator',udid,'--verbose','--profile','--max-steps','20'] + (['--validate-forms'] if args.validate_forms else [])
        + (['--compact-requests'] if args.compact_requests else []),
        stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,
        env=dict(os.environ,NSUnbufferedIO='YES',JEV_TRACE_DIR=str(out/'decisions')))
    lines=queue.Queue()
    def collect():
        for line in agent.stdout:lines.put((time.monotonic(),line))
        lines.put((time.monotonic(),None))
    threading.Thread(target=collect,daemon=True).start()
    setup=[];video=None;stop=threading.Event();audit=None;saves=[];errors=[]
    try:
        while True:
            _,line=lines.get(timeout=45)
            if line is None:raise RuntimeError('Controller exited: '+''.join(setup))
            setup.append(line)
            if 'ready     ' in line:break
        (out/'setup.log').write_text(''.join(setup))
        (out/'before.json').write_text(json.dumps(reader.tree()))
        video=subprocess.Popen(['xcrun','simctl','io',udid,'recordVideo','--codec=h264',str(out/'raw.mov')],stderr=subprocess.PIPE,text=True)
        for line in video.stderr:
            if 'Recording started' in line:break
        video_start=time.monotonic();started=time.monotonic()
        def check_saved():
            try:
                while not stop.is_set():
                    new=[r for r in saved() if r['id'] not in baseline]
                    if new:
                        saves.append({'seconds':time.monotonic()-started,'records':new});return
                    stop.wait(.05)
            except Exception as error:errors.append(str(error))
        audit=threading.Thread(target=check_saved,daemon=True);audit.start()
        agent.stdin.write(goal+'\n');agent.stdin.flush()
        events=[];success=False
        with (out/'agent.log').open('w') as log:
            while True:
                at,line=lines.get(timeout=45)
                if line is None:finish=at;break
                log.write(line);log.flush()
                if line.lstrip().startswith(('attempt   ','→','·','done      ','stopped   ','elapsed   ')):
                    events.append({'seconds':at-started,'text':line.strip()});print(f'{at-started:.3f}s {line.strip()}',flush=True)
                if 'done      ' in line:success=True
                if 'elapsed   ' in line:finish=at;break
        time.sleep(.3);stop.set();audit.join(timeout=5)
        after=reader.tree();(out/'after.json').write_text(json.dumps(after))
        new,preserved=verify_saved_contact(before_contacts,contact_snapshot(db),(args.first,args.last,args.company))
        result={'goal':goal,'agent_seconds':finish-started,'agent_start_video_seconds':started-video_start,
            'agent_claimed_success':success,'verified_saved_contact':len(new)==1 and len(saves)==1 and not errors,
            'existing_contacts_preserved':preserved,
            'saved':saves,'audit_errors':errors,'events':events,'setup':setup[-1].strip(),
            'baseline_contact_ids':sorted(baseline),
            'scoped_validation':os.environ.get('JEV_SCOPED_VALIDATION')=='1',
            'form_validation':args.validate_forms,
            'compact_requests':args.compact_requests,
            'controller_sha256':hashlib.sha256(args.controller.read_bytes()).hexdigest(),
            'simulator':udid,
            'oracle':'New matching ABPerson record, read independently from simulator SQLite; never fed to controller'}
        (out/'result.json').write_text(json.dumps(result,indent=2));print(out,flush=True);print(json.dumps(result),flush=True)
        return 0 if result['verified_saved_contact'] and preserved and success else 1
    finally:
        stop.set()
        if audit:audit.join(timeout=5)
        if video and video.poll() is None:video.send_signal(signal.SIGINT);video.wait(timeout=15)
        agent.stdin.close()
        try:agent.wait(timeout=5)
        except subprocess.TimeoutExpired:agent.terminate();agent.wait(timeout=5)
        reader.close()

if __name__=='__main__':raise SystemExit(main())
