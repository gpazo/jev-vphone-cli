"""Record Jev playing the existing Donpa app, with a separate read-only AX audit.

No board, solver, saved-state hints, or game-specific inputs reach the controller.
An exhausted budget is not a completed game; claim and observed result stay separate.
"""
import argparse, hashlib, json, os, queue, re, signal, subprocess, sys, threading, time
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tests/SafariSearch'))
from record import Reader

GOAL=('In Donpa Squad, start a new Minesweeper game on the smallest Drills board. '
      'Play using the available Board accessibility actions and try to clear the board. '
      'The Board movement actions select a cell; Dig or chord and Flag operate on the selected cell. '
      'First use a movement action to select a cell. Read the selected cell value to choose subsequent actions. '
      'Losing this game is okay. Stop when the game is won or lost.')

def summarize(tree):
    items=[];p='XC_kAXXCAttribute'
    def walk(n):
        label=n.get(p+'Label')
        if label:items.append({'label':label,'value':n.get(p+'Value'),'identifier':n.get(p+'Identifier')})
        for child in n.get(p+'Children',[]):walk(child)
    walk(tree);return items

def terminal_outcome(items):
    # From Donpa's unchanged MangaPanelView accessibility label. Only the
    # visible result panel counts, never a controller claim or hidden board.
    for item in items:
        label=item['label']
        if label.startswith(('Minefield cleared','New record! Minefield cleared')):return 'won'
        if label.startswith('Boom — you stepped on a mine.'):return 'lost'
    return 'incomplete'

def game_metrics(timeline, events):
    """Game-specific evaluation only. Never supplied to the controller."""
    clear=[];cells=set();terminal=None;segments=[]
    for entry in timeline:
        for element in entry['elements']:
            value=element.get('value') or ''
            if element['label']=='Cleared' and re.fullmatch(r'\d+%',value):
                percent=int(value[:-1])
                # A lower percentage starts a new observed board. Its opening
                # reveal cannot count as progress on the previous board.
                if not segments or percent<clear[-1]:
                    segments.append({'initial':percent,'opening':None,'maximum':percent})
                segment=segments[-1]
                if percent>0 and segment['opening'] is None:segment['opening']=percent
                segment['maximum']=max(segment['maximum'],percent)
                clear.append(percent)
            if element['label']=='Board':
                match=re.match(r'Row (\d+), column (\d+):',value)
                if match:cells.add(tuple(map(int,match.groups())))
        outcome=terminal_outcome(entry['elements'])
        if terminal is None and outcome!='incomplete':
            terminal={'seconds':entry['seconds'],'outcome':outcome}
    opening=next((n for n in clear if n>0),None)
    return {'initial_cleared_percent':clear[0] if clear else None,
        'first_nonzero_cleared_percent':opening,
        'max_cleared_percent':max(clear) if clear else None,
        'additional_clearance_after_opening':sum(s['maximum']-s['opening'] for s in segments if s['opening'] is not None) if clear else None,
        'observed_board_segments':segments,
        'distinct_observed_cells':len(cells),'first_terminal_observation':terminal,
        'acknowledged_actions_after_terminal':sum(e['text'].startswith('→') and e['seconds']>terminal['seconds'] for e in events) if terminal else 0}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--simulator',required=True)
    p.add_argument('--game-source',type=Path,default=Path('/tmp/jev-donpa'))
    p.add_argument('--max-steps',type=int,default=45)
    p.add_argument('--goal',default=GOAL)
    args=p.parse_args()
    if not 1<=args.max_steps<=100:p.error('max-steps must be 1–100')
    out=ROOT/'research/artifacts/jev-donpa'/time.strftime('%Y%m%d-%H%M%S');out.mkdir(parents=True)
    (out/'provenance.json').write_text(json.dumps({
        'controller_sha256':hashlib.sha256((ROOT/'.build/debug/vphone-cli').read_bytes()).hexdigest(),
        'helper_sha256':hashlib.sha256((ROOT/'.tools/axe/JevSimulatorPreferences').read_bytes()).hexdigest(),
        'game_commit':subprocess.check_output(['git','-C',str(args.game_source),'rev-parse','HEAD'],text=True).strip(),
        'game_changes':subprocess.check_output(['git','-C',str(args.game_source),'status','--porcelain'],text=True),
        'simulator':args.simulator,'goal':args.goal,'custom_actions':True},indent=2))
    subprocess.run(['xcrun','simctl','launch',args.simulator,'fi.misaki.donpa'],check=True)
    reader=Reader(args.simulator)
    agent=subprocess.Popen([str(ROOT/'.build/debug/vphone-cli'),'jev','--session','--simulator',args.simulator,
        '--custom-actions','--verbose','--profile','--max-steps',str(args.max_steps)],stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,
        env=dict(os.environ,NSUnbufferedIO='YES',JEV_TRACE_DIR=str(out/'decisions')))
    lines=queue.Queue()
    def collect():
        for line in agent.stdout:lines.put((time.monotonic(),line))
        lines.put((time.monotonic(),None))
    threading.Thread(target=collect,daemon=True).start()
    stop=threading.Event();timeline=[];errors=[];capture=None;observer=None
    try:
        setup=[]
        while True:
            _,line=lines.get(timeout=45)
            if line is None:raise RuntimeError('Controller startup failed: '+''.join(setup))
            setup.append(line)
            if 'ready     ' in line:break
        (out/'setup.log').write_text(''.join(setup))
        capture=subprocess.Popen(['xcrun','simctl','io',args.simulator,'recordVideo','--codec=h264',str(out/'raw.mov')],stderr=subprocess.PIPE,text=True)
        for line in capture.stderr:
            if 'Recording started' in line:break
        video_start=time.monotonic();started=time.monotonic()
        def audit():
            previous=None
            try:
                while not stop.is_set():
                    tree=reader.tree();items=summarize(tree)
                    if items!=previous:
                        timeline.append({'seconds':time.monotonic()-started,'elements':items})
                        (out/f'audit-{len(timeline):03d}.json').write_text(json.dumps(tree,indent=2))
                        previous=items
                    stop.wait(.15)
            except Exception as error:errors.append(str(error))
        observer=threading.Thread(target=audit,daemon=True);observer.start()
        print('Recording',out,flush=True)
        agent.stdin.write(args.goal+'\n');agent.stdin.flush();events=[];success=False
        with (out/'agent.log').open('w') as log:
            while True:
                at,line=lines.get(timeout=60)
                if line is None:finish=at;break
                log.write(line);log.flush()
                if line.lstrip().startswith(('attempt   ','→','·','done      ','stopped   ','gave up   ','elapsed   ')):
                    event={'seconds':at-started,'text':line.strip()};events.append(event)
                    print(f'{at-started:.3f}s {line.strip()}',flush=True)
                if 'done      ' in line:success=True
                if 'elapsed   ' in line:finish=at;break
        time.sleep(.5);stop.set();observer.join(timeout=12)
        result={'goal':args.goal,'agent_seconds':finish-started,'agent_claimed_success':success,
            'setup':setup[-1].strip(),'agent_start_video_seconds':started-video_start,
            'events':events,'audit_errors':errors,'timeline':timeline,
            'game_outcome':terminal_outcome(timeline[-1]['elements']) if timeline and not errors else 'unknown'}
        result['game_metrics']=game_metrics(timeline,events)
        result['game_metrics']['audit_complete']=bool(timeline) and not errors
        (out/'result.json').write_text(json.dumps(result,indent=2))
        print(out,flush=True)
    finally:
        stop.set()
        if observer:observer.join(timeout=12)
        if capture and capture.poll() is None:capture.send_signal(signal.SIGINT);capture.wait(timeout=20)
        agent.stdin.close()
        try:agent.wait(timeout=5)
        except subprocess.TimeoutExpired:agent.terminate();agent.wait(timeout=5)
        reader.close()

if __name__=='__main__':main()
