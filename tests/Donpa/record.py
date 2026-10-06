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
    root_frame = tree.get(p+'Frame') or {}
    def walk(n, path=''):
        label=n.get(p+'Label')
        if label:
            items.append({'label':label,'value':n.get(p+'Value'),'identifier':n.get(p+'Identifier'),
                          'path':path,'element_type':n.get(p+'ElementType'),
                          'automation_type':n.get(p+'AutomationType'),
                          'frame':n.get(p+'Frame'),'root_frame':root_frame})
        for index, child in enumerate(n.get(p+'Children',[])):
            walk(child, f'{path}/{index}')
    walk(tree);return items

WIN_LABEL = re.compile(
    r'^(?:Minefield cleared|New record! Minefield cleared in .+)'
    r'(?: (?:Won on a forced guess|Best pace|Pace|Unlocked:).*)?$')
LOSS_LABEL = re.compile(
    r'^Boom — you stepped on a mine\. '
    r'(?:Cleared \d+%|So close — \d+ (?:tiles|cells) left)\.'
    r'(?: .*)?$')

def _has_result_shape(item):
    """Return (known, valid) for the native result-node shape.

    Existing traces predate shape fields, so unknown is retained for legacy
    metrics. New traces require the accessibility image role and geometry.
    """
    fields = ('automation_type', 'element_type', 'frame')
    if not any(field in item for field in fields):
        return False, True
    automation = item.get('automation_type')
    frame = item.get('frame') or {}
    root = item.get('root_frame') or {}
    try:
        import math
        x, y = float(frame.get('X', 0)), float(frame.get('Y', 0))
        width, height = float(frame.get('Width', 0)), float(frame.get('Height', 0))
        rx, ry = float(root.get('X', 0)), float(root.get('Y', 0))
        rwidth, rheight = float(root.get('Width', 0)), float(root.get('Height', 0))
        values = (x, y, width, height, rx, ry, rwidth, rheight)
        geometry = all(math.isfinite(value) for value in values)
        geometry = geometry and width > 0 and height > 0 and rwidth > 0 and rheight > 0
        geometry = geometry and min(x + width, rx + rwidth) > max(x, rx)
        geometry = geometry and min(y + height, ry + rheight) > max(y, ry)
    except (TypeError, ValueError):
        geometry = False
    # AX automation type 43 is the image trait used by the native panel in the
    # retained audits. Do not claim visibility; geometry is only shape evidence.
    return True, automation == 43 and item.get('element_type') == 'SwiftUI.AccessibilityNode' and geometry

def terminal_evidence(items):
    """Return a candidate result-panel observation, or None.

    This is deliberately a candidate: raw AX trees do not expose an
    authoritative visibility bit. The caller must confirm a stable sample and
    (when claiming a win) an independent screenshot.
    """
    for item in items:
        label = item.get('label') or ''
        outcome = 'won' if WIN_LABEL.fullmatch(label) else 'lost' if LOSS_LABEL.fullmatch(label) else None
        if outcome is None:
            continue
        known, shape = _has_result_shape(item)
        if not shape:
            continue
        if outcome == 'won' and not any(
                other.get('label') == 'Cleared' and other.get('value') == '100%'
                for other in items):
            continue
        return {'outcome': outcome, 'label': label, 'path': item.get('path'),
                'shape_verified': known and shape}
    return None

def terminal_outcome(items):
    """Legacy outcome API; exact syntax is required, shape is best-effort."""
    evidence = terminal_evidence(items)
    return evidence['outcome'] if evidence else 'incomplete'

def _planner_path(jev_args):
    """Return the explicitly supplied planner executable path, if any."""
    for index, argument in enumerate(jev_args):
        if argument == '--planner' and index + 1 < len(jev_args):
            return jev_args[index + 1]
        if argument.startswith('--planner='):
            return argument.split('=', 1)[1]
    return None

def _file_sha256(path):
    """Hash one explicitly named executable; return None when unset/missing."""
    if not path:
        return None
    try:
        digest = hashlib.sha256()
        with Path(path).open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        return digest.hexdigest()
    except (OSError, ValueError):
        return None

def _terminal_stability(timeline, required=2):
    run = []
    for index, entry in enumerate(timeline):
        evidence = entry.get('terminal_evidence') or terminal_evidence(entry.get('elements', []))
        if evidence is None:
            run = []
        elif run and (evidence['outcome'], evidence.get('label'), evidence.get('path')) == \
                (run[-1]['outcome'], run[-1].get('label'), run[-1].get('path')):
            run.append(evidence)
        else:
            run = [evidence]
    if len(run) >= required:
        return {'outcome': run[-1]['outcome'], 'label': run[-1]['label'],
                'first_seconds': timeline[len(timeline) - len(run)]['seconds'],
                'samples': len(run), 'shape_verified': all(x['shape_verified'] for x in run)}
    return None

def is_native_input(event):
    text = event.get("text", "")
    return text.startswith("→") and not re.match(r"^→\s*\d+\s+wait\b", text)

def game_metrics(timeline, events):
    """Game-specific evaluation only. Never supplied to the controller."""
    clear=[];cells=set();terminal=None;segments=[]
    restart_times = [e['seconds'] for e in events
                     if is_native_input(e) and
                     re.search(r'\b(?:Retry|New game)\b', e.get('text',''), re.I)]
    restart_index = 0
    for entry in timeline:
        while restart_index < len(restart_times) and entry['seconds'] >= restart_times[restart_index]:
            # A visible Retry/New game action is a stronger boundary than a
            # percentage decrease: the replacement board may open higher.
            segments.append({'initial':None,'opening':None,'maximum':None})
            restart_index += 1
        for element in entry['elements']:
            value=element.get('value') or ''
            if element['label']=='Cleared' and re.fullmatch(r'\d+%',value):
                percent=int(value[:-1])
                # A lower percentage starts a new observed board. Its opening
                # reveal cannot count as progress on the previous board.
                if not segments or (segments[-1]['maximum'] is not None and percent < clear[-1]):
                    segments.append({'initial':percent,'opening':None,'maximum':percent})
                segment=segments[-1]
                if segment['initial'] is None:
                    segment['initial'] = percent
                if percent>0 and segment['opening'] is None:segment['opening']=percent
                segment['maximum'] = percent if segment['maximum'] is None else max(segment['maximum'], percent)
                clear.append(percent)
            if element['label']=='Board':
                match=re.match(r'Row (\d+), column (\d+):',value)
                if match:cells.add(tuple(map(int,match.groups())))
        outcome_evidence = entry.get('terminal_evidence') or terminal_evidence(entry['elements'])
        outcome = outcome_evidence['outcome'] if outcome_evidence else 'incomplete'
        if terminal is None and outcome!='incomplete':
            terminal={'seconds':entry['seconds'],'outcome':outcome}
            if outcome_evidence.get('shape_verified'):
                terminal.update(label=outcome_evidence['label'], shape_verified=True)
    stable = _terminal_stability(timeline)
    post_terminal = sum(
        1 for e in events if is_native_input(e) and terminal is not None
        and e['seconds'] > terminal['seconds'])
    opening=next((n for n in clear if n>0),None)
    return {'initial_cleared_percent':clear[0] if clear else None,
        'first_nonzero_cleared_percent':opening,
        'max_cleared_percent':max(clear) if clear else None,
        'additional_clearance_after_opening':sum(s['maximum']-s['opening'] for s in segments if s['opening'] is not None) if clear else None,
        'observed_board_segments':segments,
        'distinct_observed_cells':len(cells),'first_terminal_observation':terminal,
        'acknowledged_actions_after_terminal':post_terminal,
        'stable_terminal_observation':stable,
        'stable_win_candidate':bool(stable and stable['outcome']=='won' and post_terminal==0 and
                                    stable['shape_verified']),
        'terminal_candidate':terminal}

def source_provenance(path):
    commit = subprocess.run(['git','-C',str(path),'rev-parse','HEAD'], text=True, capture_output=True)
    if commit.returncode:
        return {'commit':None, 'changes':None, 'error':commit.stderr.strip()}
    changes = subprocess.run(['git','-C',str(path),'status','--porcelain'], text=True, capture_output=True)
    return {'commit':commit.stdout.strip(), 'changes':changes.stdout if changes.returncode==0 else None,
            'error':changes.stderr.strip() if changes.returncode else None}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--simulator',required=True)
    p.add_argument('--game-source',type=Path,default=Path('/tmp/jev-donpa'))
    p.add_argument('--binary',type=Path,default=ROOT/'.build/debug/vphone-cli',
                   help='Signed controller binary to run and hash')
    p.add_argument('--max-steps',type=int,default=45)
    p.add_argument('--max-seconds',type=float,default=600)
    p.add_argument('--operator-setup-note',default=None)
    p.add_argument('--jev-arg',action='append',default=[],
                   help='Additional isolated argument passed to the Jev controller (repeatable)')
    p.add_argument('--goal',default=GOAL)
    args=p.parse_args()
    if not 1<=args.max_steps<=1000:p.error('max-steps must be 1–1000')
    if not 1<=args.max_seconds<=3600:p.error('max-seconds must be 1–3600')
    out=ROOT/'research/artifacts/jev-donpa'/time.strftime('%Y%m%d-%H%M%S');out.mkdir(parents=True)
    app_container = subprocess.check_output(
        ['xcrun','simctl','get_app_container',args.simulator,'fi.misaki.donpa','app'], text=True).strip()
    app_hash = hashlib.sha256()
    app_root = Path(app_container)
    for path in sorted(app_root.rglob('*')):
        if path.is_file():
            app_hash.update(str(path.relative_to(app_root)).encode())
            app_hash.update(path.read_bytes())
    deadline = time.monotonic() + args.max_seconds
    planner_path = _planner_path(args.jev_arg)
    codex_binary = os.environ.get('JEV_CODEX_BINARY')
    planner_model = os.environ.get('JEV_PLANNER_MODEL')
    game_source = source_provenance(args.game_source)
    (out/'provenance.json').write_text(json.dumps({
        'controller_sha256':hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        'controller_binary':str(args.binary.resolve()),
        'helper_sha256':hashlib.sha256((ROOT/'.tools/axe/JevSimulatorPreferences').read_bytes()).hexdigest(),
        'game_commit':game_source['commit'],
        'game_changes':game_source['changes'],
        'game_source_error':game_source['error'],
        'simulator':args.simulator,'goal':args.goal,'custom_actions':True,
        'jev_args':args.jev_arg,
        'planner_executable':planner_path,
        'planner_executable_sha256':_file_sha256(planner_path),
        'jev_codex_binary_sha256':_file_sha256(codex_binary),
        'jev_planner_model':planner_model,
        'jev_planner_reasoning_effort':os.environ.get('JEV_PLANNER_REASONING_EFFORT'),
        'app_container':app_container,'app_bundle_sha256':app_hash.hexdigest(),
        'operator_setup_note':args.operator_setup_note},indent=2))
    subprocess.run(['xcrun','simctl','launch',args.simulator,'fi.misaki.donpa'],check=True)
    reader=Reader(args.simulator)
    agent_command=[str(args.binary.resolve()),'jev','--session','--simulator',args.simulator,
        '--custom-actions','--verbose','--profile','--max-steps',str(args.max_steps),*args.jev_arg]
    agent=subprocess.Popen(agent_command,stdin=subprocess.PIPE,
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
        try:
            while True:
                remaining=max(0.1, deadline-time.monotonic())
                _,line=lines.get(timeout=min(45,remaining))
                if line is None:raise RuntimeError('Controller startup failed: '+''.join(setup))
                setup.append(line)
                if 'ready     ' in line:break
        except (queue.Empty, TimeoutError, RuntimeError) as error:
            (out/'result.json').write_text(json.dumps({
                'goal': args.goal, 'agent_claimed_success': False,
                'setup': setup[-1].strip() if setup else None,
                'events': [], 'audit_errors': [], 'timeline': [],
                'error': str(error), 'audit_complete': False,
                'stable_win_candidate': False}, indent=2))
            raise
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
                    evidence = terminal_evidence(items)
                    if items!=previous or evidence:
                        timeline.append({'seconds':time.monotonic()-started,'elements':items,
                                         'terminal_evidence':evidence})
                        (out/f'audit-{len(timeline):03d}.json').write_text(json.dumps(tree,indent=2))
                        previous=items
                    stop.wait(.15)
            except Exception as error:errors.append(str(error))
        observer=threading.Thread(target=audit,daemon=True);observer.start()
        print('Recording',out,flush=True)
        agent.stdin.write(args.goal+'\n');agent.stdin.flush();events=[];success=False
        run_error = None
        with (out/'agent.log').open('w') as log:
            try:
                while True:
                    remaining=max(0.1, deadline-time.monotonic())
                    if remaining <= 0.1:
                        raise TimeoutError(f'controller exceeded --max-seconds {args.max_seconds}')
                    at,line=lines.get(timeout=min(60,remaining))
                    if line is None:finish=at;break
                    log.write(line);log.flush()
                    if line.lstrip().startswith(('attempt   ','→','·','done      ','stopped   ','gave up   ','elapsed   ')):
                        event={'seconds':at-started,'text':line.strip()};events.append(event)
                        print(f'{at-started:.3f}s {line.strip()}',flush=True)
                    if 'done      ' in line:success=True
                    if 'elapsed   ' in line:finish=at;break
            except (TimeoutError, queue.Empty) as error:
                run_error = str(error)
                finish = time.monotonic()
        time.sleep(.5);stop.set();observer.join(timeout=12)
        metrics = game_metrics(timeline, events)
        terminal_screenshot = None
        if metrics['stable_win_candidate'] and not errors:
            terminal_screenshot = out/'terminal.png'
            try:
                subprocess.run(
                    ['xcrun', 'simctl', 'io', args.simulator, 'screenshot', str(terminal_screenshot)],
                    check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
            except (OSError, subprocess.CalledProcessError) as error:
                terminal_screenshot = None
                errors.append(f'terminal screenshot failed: {error}')
        result={'goal':args.goal,'agent_seconds':finish-started,'agent_claimed_success':success,
            'setup':setup[-1].strip(),'agent_start_video_seconds':started-video_start,
            'events':events,'audit_errors':errors,'timeline':timeline,
            'error':run_error,
            'terminal_screenshot':str(terminal_screenshot) if terminal_screenshot else None,
            'game_outcome':terminal_outcome(timeline[-1]['elements']) if timeline and not errors else 'unknown'}
        result['game_metrics']=metrics
        result['game_metrics']['audit_complete']=bool(timeline) and not errors
        result['audit_complete']=result['game_metrics']['audit_complete']
        result['stable_win_candidate']=bool(
            result['game_metrics']['stable_win_candidate'] and result['audit_complete'] and not run_error)
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
