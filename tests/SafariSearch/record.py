"""Live Safari evaluation. The controller gets only the goal; this harness independently audits native AX and Safari history."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import signal
import socket
import sqlite3
import struct
import subprocess
import threading
import time
from urllib.parse import urlsplit
import uuid

ROOT = Path(__file__).resolve().parents[2]
QUERY = 'swift programming language'
GOAL = (f'In Safari, search Google for "{QUERY}". Open the first organic web result, '
        'return to the Google results using Back, then open the second organic web result. '
        'Exclude ads, AI Overview citations, navigation links and site links. '
        'Dismiss optional prompts if necessary. Stop after the second result page has loaded.')

class Reader:
    """Independent read-only accessibility connection, never used by the controller."""
    def __init__(self, udid):
        self.path = f'/tmp/jev-eval-{uuid.uuid4().hex}.sock'
        self.process = subprocess.Popen(['xcrun','simctl','spawn',udid,str(ROOT/'.tools/axe/SimulatorFrameworkBridge-iOS'),
            'accessibility','serve',self.path,'--idle-timeout','120','--exit-on-disconnect','true'],
            stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        deadline = time.monotonic()+10
        while not Path(self.path).exists():
            if time.monotonic()>deadline: raise RuntimeError('Evaluator reader did not start')
            time.sleep(.02)
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(10)
        self.socket.connect(self.path)
    def read(self, size):
        chunks = b''
        while len(chunks)<size:
            part = self.socket.recv(size-len(chunks))
            if not part: raise EOFError('Evaluator reader disconnected')
            chunks += part
        return chunks
    def tree(self):
        payload=json.dumps({'verb':'describe','method':'window-server','x':0,'y':0,'snapshotTree':True,'automationMode':True,'maxNodes':20000}).encode()
        self.socket.sendall(struct.pack('!I',len(payload))+payload)
        result=json.loads(self.read(struct.unpack('!I',self.read(4))[0]))
        if not result.get('ok') or result.get('truncated'): raise RuntimeError('Incomplete evaluator tree')
        return result['tree']
    def close(self):
        self.socket.close()
        try:self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:self.process.terminate();self.process.wait(timeout=3)
        Path(self.path).unlink(missing_ok=True)

def result_links(tree):
    """Google-specific oracle, outside the generic controller. Keep raw evidence for review."""
    results=[]
    def walk(node, ancestors):
        p='XC_kAXXCAttribute'
        label=node.get(p+'Label') or ''
        if node.get(p+'AutomationType')==42 and node.get(p+'Value')=='3':
            context=' '.join(ancestors)
            urls=re.findall(r'https?://[^\s]+',context)
            if urls and not any(x in context.lower() for x in ['sponsored','ads, region','ai overview']):
                item={'title':label,'display_url':urls[-1], 'host':urlsplit(urls[-1]).hostname}
                if label and item['host'] and item not in results:results.append(item)
        for child in node.get(p+'Children',[]):walk(child,ancestors+([label] if label else []))
    walk(tree,[])
    return results


def page_state(tree):
    p='XC_kAXXCAttribute'
    title=None;address='';content=0
    def walk(node):
        nonlocal title,address,content
        label=node.get(p+'Label') or ''
        if node.get(p+'ElementType')=='WebAccessibilityObjectWrapper':
            if title is None and label:title=label
            content+=len(label)
        if label=='Address':address=node.get(p+'Value') or ''
        for child in node.get(p+'Children',[]):walk(child)
    walk(tree)
    return {'document_title':title,'address':address.replace('\u200e',''),'content_characters':content}

def search_state(entry, query=QUERY):
    return entry['document_title']==query+' - Google Search' and (
        entry['address']==query or 'google.com' in entry['address'])


def verify_sequence(timeline, ranked, query):
    def destination(entry, expected):
        address=entry['address']
        host=(urlsplit(address if '://' in address else '//'+address).hostname or '').removeprefix('www.')
        title=expected['title'].casefold()
        actual=(entry['document_title'] or '').casefold()
        # Search engines visibly shorten long headings. Match the substantial
        # exposed prefix, still requiring the independent host and loaded body.
        if title.endswith(('...', '…')):
            title=title.rstrip('.… ').strip()
            title_matches=len(title)>=12 and actual.startswith(title)
        else:title_matches=title in actual
        return (host==expected['host'].removeprefix('www.')
            and title_matches
            and entry['content_characters']>100 and entry['document_title']!=query+' - Google Search')
    stage=0;milestones=[]
    for entry in timeline:
        if stage in [0,2] and search_state(entry,query):
            milestones.append(entry);stage+=1
        elif stage in [1,3] and len(ranked)==2:
            expected=ranked[0 if stage==1 else 1]
            if destination(entry,expected):
                milestones.append(entry);stage+=1
    # "Stop after the second result" also constrains the final state. Visiting
    # it and then leaving again is not a passing terminal outcome.
    return stage==4 and destination(timeline[-1],ranked[1]),milestones

def actions_started_after_load(events, milestones):
    """Match acknowledged inputs to attempts; the navigation itself may acknowledge late."""
    if len(milestones)<4:return []
    loaded=milestones[3]['seconds'];attempts={};extra=[]
    for event in events:
        start=re.match(r'^attempt\s+(\d+)\s',event['text'])
        acknowledged=re.match(r'^→\s*(\d+)\s',event['text'])
        if start:attempts[start[1]]=event['seconds']
        if acknowledged and attempts.get(acknowledged[1],float('-inf'))>loaded:
            extra.append(event)
    return extra

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator',default='booted')
    parser.add_argument('--query',default=QUERY)
    parser.add_argument('--controller',type=Path,default=ROOT/'.build/debug/vphone-cli',help='Controller executable for paired measurements')
    parser.add_argument('--terminal-choice-completion',action='store_true',help='Experiment with terminal-choice completion')
    args=parser.parse_args()
    if not args.query.strip():parser.error("query must not be empty")
    goal=GOAL.replace(QUERY,args.query)
    udid=args.simulator
    if udid=='booted':
        devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','booted','--json']))
        ids=[d['udid'] for g in devices['devices'].values() for d in g if d['state']=='Booted']
        if len(ids)!=1:parser.error('Specify one booted simulator UDID')
        udid=ids[0]
    out=ROOT/'research/artifacts/jev-safari'/time.strftime('%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    # Identify the executable even with uncommitted edits in this research checkout.
    (out/'provenance.json').write_text(json.dumps({
        'binary_sha256':hashlib.sha256(args.controller.read_bytes()).hexdigest(),
        'recorder_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'git_head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        'query':args.query, 'simulator':udid,
    },indent=2))
    subprocess.run(['xcrun','simctl','openurl',udid,'https://example.com/'],check=True)
    # Fixture initialization is excluded from ready-session goal time.
    time.sleep(1)
    db=Path.home()/f'Library/Developer/CoreSimulator/Devices/{udid}/data/Library/Safari/SafariTabs.db'
    reader=Reader(udid)
    # A cold launch can exceed the old one-second sleep. Verify the fixture
    # before starting the controller; this is setup, never agent goal time.
    fixture_started=time.monotonic();fixture_deadline=fixture_started+15
    while True:
        try:
            fixture=page_state(reader.tree())
            if fixture['document_title']=='Example Domain' and fixture['address']=='example.com':break
        except Exception:
            pass
        if time.monotonic()>=fixture_deadline:
            reader.close();raise RuntimeError('Safari fixture did not become ready on example.com')
        time.sleep(.1)
    (out/'fixture.json').write_text(json.dumps({'seconds':time.monotonic()-fixture_started,'state':fixture},indent=2))
    agent=subprocess.Popen([str(args.controller.resolve()),'jev','--session','--simulator',udid,
        '--verbose','--profile','--max-steps','25']+(['--terminal-choice-completion'] if args.terminal_choice_completion else []),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
        text=True,env=dict(os.environ,NSUnbufferedIO='YES',JEV_TRACE_DIR=str(out/'decisions')))
    lines=queue.Queue()
    def collect():
        for line in agent.stdout:lines.put((time.monotonic(),line))
        lines.put((time.monotonic(),None))
    threading.Thread(target=collect,daemon=True).start()
    stop=threading.Event();timeline=[];ranked=[];audit_errors=[];audit_reads=[];record=None
    setup=[];observer=None
    try:
        while True:
            _,line=lines.get(timeout=30)
            if line is None:
                (out/'setup.log').write_text(''.join(setup))
                raise RuntimeError('Agent failed to initialize: '+''.join(setup))
            setup.append(line)
            if 'ready     ' in line:break
        (out/'setup.log').write_text(''.join(setup))
        record=subprocess.Popen(['xcrun','simctl','io',udid,'recordVideo','--codec=h264',str(out/'raw.mov')],stderr=subprocess.PIPE,text=True)
        for line in record.stderr:
            if 'Recording started' in line:break
        video_started=time.monotonic()
        with sqlite3.connect(db.with_name('History.db').as_uri()+'?mode=ro',uri=True) as history:
            history_baseline=history.execute('select coalesce(max(id),0) from history_visits').fetchone()[0]
        started=time.monotonic()
        def audit():
            try:
                previous=None
                while not stop.is_set():
                    read_started=time.monotonic()
                    tree=reader.tree()
                    audit_reads.append({'seconds':time.monotonic()-started,'duration':time.monotonic()-read_started})
                    entry=page_state(tree)
                    key=(entry['document_title'],entry['address'],entry['content_characters']>100)
                    if key!=previous:
                        entry['seconds']=time.monotonic()-started
                        timeline.append(entry)
                        (out/f"audit-{len(timeline):03d}.json").write_text(json.dumps(tree,indent=2))
                        previous=key
                    if search_state(entry,args.query) and not ranked:
                        found=result_links(tree)
                        if len(found)>=2:
                            ranked.extend(found[:2]);(out/'search-tree.json').write_text(json.dumps(tree,indent=2))
                    # Once the independent route is proved, repeated full
                    # document reads only contend with the controller. Input
                    # timestamps still detect late actions, and a separate
                    # fresh read after completion verifies the final state.
                    if verify_sequence(timeline,ranked,args.query)[0]:break
                    stop.wait(.1)
            except Exception as error:audit_errors.append(str(error))
        observer=threading.Thread(target=audit,daemon=True);observer.start()
        agent.stdin.write(goal+'\n');agent.stdin.flush()
        events=[];success=False
        with (out/'agent.log').open('w') as log:
            while True:
                at,line=lines.get(timeout=45)
                if line is None:finish=at;break
                log.write(line);log.flush()
                if any(token in line for token in ['attempt   ','→','done      ','stopped   ','elapsed   ']):
                    events.append({'seconds':at-started,'text':line.strip()});print(f'{at-started:.3f}s {line.strip()}',flush=True)
                if 'done      ' in line:success=True
                if 'elapsed   ' in line:finish=at;break
        time.sleep(.5);stop.set();observer.join(timeout=12)
        if observer.is_alive():audit_errors.append('Evaluator did not stop before final verification')
        else:
            try:
                read_started=time.monotonic();tree=reader.tree()
                audit_reads.append({'seconds':time.monotonic()-started,'duration':time.monotonic()-read_started,'final':True})
                entry=page_state(tree);entry['seconds']=time.monotonic()-started
                timeline.append(entry);(out/'audit-final.json').write_text(json.dumps(tree,indent=2))
            except Exception as error:audit_errors.append('Final verification: '+str(error))
        # Require search -> actual first destination -> same query after Back -> second destination.
        verified,milestones=verify_sequence(timeline,ranked,args.query)
        history_db=db.with_name('History.db')
        with sqlite3.connect(history_db.as_uri()+'?mode=ro',uri=True) as history:
            visits=[dict(zip(['id','url','title','loaded'],row)) for row in history.execute(
                'select v.id,i.url,v.title,v.load_successful from history_visits v join history_items i on i.id=v.history_item where v.id>? order by v.id', (history_baseline,)).fetchall()]
        passed=verified and not audit_errors
        extra_actions=actions_started_after_load(events,milestones)
        result={'goal':goal,'mode':'ready session, starting in Safari on example.com','setup':setup[-1].strip(),
            'agent_seconds':finish-started,'agent_start_video_seconds':started-video_started,
            'agent_claimed_success':success,'verified_sequence':passed,
            'actions_started_after_second_page':extra_actions,
            'verified_stop_after_second_page':passed and not extra_actions,
            'completion_policy':'terminal choice majority' if args.terminal_choice_completion else 'corroborated',
            'new_history_visits':visits,'ranked_results':ranked,'milestones':milestones,'ui_timeline':timeline,'audit_errors':audit_errors,
            'audit_reads':audit_reads,'audit_policy':'Poll until route observed; fresh final tree after controller completion',
            'events':events,'oracle':'Independent native AX result order, document title, address and content; not fed to Jev'}
        (out/'result.json').write_text(json.dumps(result,indent=2))
        print(out,flush=True);print(json.dumps({k:v for k,v in result.items() if k not in ['events','ui_timeline']}),flush=True)
        return 0 if passed and success and not extra_actions else 1
    finally:
        stop.set()
        if observer:observer.join(timeout=12)
        if record and record.poll() is None:record.send_signal(signal.SIGINT);record.wait(timeout=15)
        agent.stdin.close()
        try:agent.wait(timeout=5)
        except subprocess.TimeoutExpired:agent.terminate();agent.wait(timeout=5)
        reader.close()

if __name__=='__main__':raise SystemExit(main())
