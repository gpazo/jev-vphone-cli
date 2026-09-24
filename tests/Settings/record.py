"""Record both directions of two Settings switches; audit native values and stored preferences."""
import json,subprocess,sys,os,time,threading,queue,signal,hashlib
from pathlib import Path
root=Path(__file__).resolve().parents[2];sys.path.insert(0,str(root/'tests/SafariSearch'));from record import Reader
devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','booted','--json']))
ids=[d['udid'] for group in devices['devices'].values() for d in group if d['state']=='Booted']
if len(ids)!=1:raise RuntimeError('Exactly one booted simulator is required')
u=ids[0]
out=root/'research/artifacts/jev-settings'/time.strftime('%Y%m%d-%H%M%S');out.mkdir(parents=True)
subprocess.run(['xcrun','simctl','launch',u,'com.apple.Preferences'],check=True)
r=Reader(u)
controller=Path(os.environ.get('JEV_CONTROLLER',str(root/'.build/debug/vphone-cli'))).resolve()
p=subprocess.Popen([str(controller),'jev','--session','--simulator',u,'--verbose','--profile','--max-steps','20'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=dict(os.environ,NSUnbufferedIO='YES',JEV_TRACE_DIR=str(out/'decisions')))
q=queue.Queue()
def collect():
 for line in p.stdout:q.put((time.monotonic(),line))
 q.put((time.monotonic(),None))
threading.Thread(target=collect,daemon=True).start()
setup=[];video=None
try:
 while True:
  _,line=q.get(timeout=45)
  if line is None:raise RuntimeError(''.join(setup))
  setup.append(line)
  if 'ready     ' in line:break
 (out/'setup.log').write_text(''.join(setup))
 for target in ['on','off']:
  folder=out/target;folder.mkdir();goal=f'In Settings, turn {target} Bold Text and Increase Contrast in Accessibility, Display & Text Size. Stop when both are {target}.'
  before=r.tree();(folder/'before.json').write_text(json.dumps(before,indent=2))
  prefs=lambda: json.loads(subprocess.run(['xcrun','simctl','spawn',u,str(root/'.tools/axe/JevSimulatorPreferences')],input='["com.apple.Accessibility"]\n',capture_output=True,text=True,check=True,timeout=15).stdout)
  beforeprefs=prefs()
  video=subprocess.Popen(['xcrun','simctl','io',u,'recordVideo','--codec=h264',str(folder/'raw.mov')],stderr=subprocess.PIPE,text=True)
  for line in video.stderr:
   if 'Recording started' in line:break
  started=time.monotonic();events=[];success=False
  p.stdin.write(goal+'\n');p.stdin.flush()
  with (folder/'agent.log').open('w') as log:
   while True:
    at,line=q.get(timeout=45)
    if line is None:raise RuntimeError('Controller exited')
    log.write(line);log.flush()
    if line.lstrip().startswith(('attempt   ','→','·','done      ','stopped   ','elapsed   ')):
     events.append({'seconds':at-started,'text':line.strip()});print(f'{target} {at-started:.3f}s {line.strip()}',flush=True)
    if line.lstrip().startswith('done      '):success=True
    if line.lstrip().startswith('elapsed   '):end=at-started;break
  after=r.tree();(folder/'after.json').write_text(json.dumps(after,indent=2));afterprefs=prefs()
  switches={}
  def walk(n):
   k='XC_kAXXCAttribute';label=n.get(k+'Label')
   if label in ['Bold Text','Increase Contrast'] and n.get(k+'AutomationType')==40:switches[label]=n.get(k+'Value')
   for child in n.get(k+'Children',[]):walk(child)
  walk(after);verified=all(str(switches.get(label))==('1' if target=='on' else '0') for label in ['Bold Text','Increase Contrast'])
  stored=afterprefs.get('com.apple.Accessibility',{})
  prefs_verified=all(str(stored.get(key))==('1' if target=='on' else '0') for key in ['EnhancedTextLegibilityEnabled','DarkenSystemColors'])
  result={'goal':goal,'agent_seconds':end,'agent_claimed_success':success,'verified_switches':verified,'verified_preferences':prefs_verified,'switches':switches,'events':events,'before_preferences':beforeprefs,'after_preferences':afterprefs,'setup':setup[-1].strip(),'controller_sha256':hashlib.sha256(controller.read_bytes()).hexdigest(),'scoped_validation':os.environ.get('JEV_SCOPED_VALIDATION')=='1'}
  (folder/'result.json').write_text(json.dumps(result,indent=2));print(folder,'VERIFIED',verified,'CLAIM',success,flush=True)
  time.sleep(.5);video.send_signal(signal.SIGINT);video.wait(timeout=20);video=None
  if not verified or not prefs_verified:break
finally:
 if video and video.poll() is None:video.send_signal(signal.SIGINT);video.wait(timeout=20)
 p.stdin.close()
 try:p.wait(timeout=5)
 except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=5)
 r.close()
print(out,flush=True)
