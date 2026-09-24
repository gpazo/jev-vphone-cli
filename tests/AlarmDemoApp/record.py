"""Record Jev's live alarm task from a ready session; independently verify cfprefsd.

Run after make setup_jev and make patcher_build. Requires the unmodified
AlarmDemoApp installed on a booted simulator. No goal actions are precomputed.
"""
import argparse,subprocess,threading,queue,time,signal,json,pathlib,os,base64,re
root=pathlib.Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--simulator',default='booted')
parser.add_argument('--runs',type=int,default=1,help='Repeat the list of times this many times')
parser.add_argument('--times',nargs='+',default=['6AM'],help='Alarm times, e.g. 6AM 12PM 6PM')
args=parser.parse_args()
if not 1 <= args.runs <= 10:parser.error('--runs must be between 1 and 10')
targets=[]
for requested in args.times:
 match=re.fullmatch(r'(1[0-2]|[1-9])(?::([0-5][0-9]))?\s*(AM|PM)',requested.upper())
 if not match:parser.error('times must use 12-hour notation, e.g. 6AM or 12:00PM')
 hour,minute,period=int(match[1]),int(match[2] or 0),match[3]
 targets.append((f'{hour}:{minute:02d} {period}',hour%12+(12 if period=='PM' else 0),minute))
udid=args.simulator
if udid=='booted':
 devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','booted','--json'],text=True))
 ids=[d['udid'] for group in devices['devices'].values() for d in group if d['state']=='Booted']
 if len(ids)!=1:parser.error('specify a simulator UDID when exactly one is not booted')
 udid=ids[0]
container=subprocess.check_output(['xcrun','simctl','get_app_container',udid,'com.jevdemo.alarm','data'],text=True).strip()
def alarms():
 command={'operation':'read-data','domain':'com.jevdemo.alarm','container':container,'key':'alarms'}
 r=subprocess.run(['xcrun','simctl','spawn',udid,str(root/'.tools/axe/JevSimulatorPreferences')],input=json.dumps(command)+'\n',capture_output=True,text=True,check=True)
 return json.loads(base64.b64decode(json.loads(r.stdout)['data']))
subprocess.run([str(root/'.tools/axe/axe'),'button','home','--udid',udid],check=True)
p=subprocess.Popen([str(root/'.build/debug/vphone-cli'),'jev','--session','--simulator',udid,'--max-steps','16','--verbose','--profile'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=dict(os.environ,NSUnbufferedIO='YES'))
q=queue.Queue()
def read():
 for line in p.stdout:q.put((time.monotonic(),line))
 q.put((time.monotonic(),None))
threading.Thread(target=read,daemon=True).start()
setup=[]
while True:
 at,line=q.get(timeout=30)
 if line is None:raise RuntimeError('session exited before ready: '+''.join(setup))
 setup.append(line)
 if 'ready     ' in line:print(line.strip(),flush=True);break
try:
 for trial,(label,expected_hour,expected_minute) in enumerate(targets*args.runs):
  if trial:subprocess.run([str(root/'.tools/axe/axe'),'button','home','--udid',udid],check=True);time.sleep(.8)
  out=root/'research/artifacts/jev-alarm'/time.strftime('%Y%m%d-%H%M%S');out.mkdir(parents=True)
  before=alarms();(out/'before.json').write_text(json.dumps(before,indent=2));(out/'setup.log').write_text(''.join(setup))
  record=subprocess.Popen(['xcrun','simctl','io',udid,'recordVideo','--codec=h264',str(out/'raw.mov')],stderr=subprocess.PIPE,text=True)
  for line in record.stderr:
   if 'Recording started' in line:break
  video_start=time.monotonic();start=time.monotonic();print('Recording',out,flush=True)
  goal=f'Add a new alarm for {label} in the Alarms app and save it.'
  p.stdin.write(goal+'\n');p.stdin.flush();events=[];success=False;error=None
  with (out/'agent.log').open('w') as log:
   while True:
    at,line=q.get(timeout=35)
    if line is None:
     finish=at;error='Session exited before reporting completion; see agent.log';break
    log.write(line);log.flush()
    if '→' in line or '·' in line or 'done      ' in line or 'elapsed' in line or 'timing total' in line:
     print(f'{at-start:.3f}s {line.strip()}',flush=True);events.append({'seconds':at-start,'text':line.strip()})
    if 'done      ' in line:success=True
    if 'elapsed   ' in line:finish=at;break
  # Audit with an independent guest process; app storage is not fed to the
  # controller. Disk writes may lag. Report this audit's duration separately.
  audit_start=time.monotonic()
  while True:
   after=alarms();new=[a for a in after if a['id'] not in {a['id'] for a in before}]
   if new or time.monotonic()-audit_start>3:break
   time.sleep(.02)
  audit=time.monotonic()-audit_start
  time.sleep(.5);record.send_signal(signal.SIGINT);record.wait(timeout=15)
  result={'goal':goal,'error':error,'agent_seconds':finish-start,'agent_start_video_seconds':start-video_start,'agent_exit':0 if success else 1,'new_alarms':new,'expected_hour':expected_hour,'expected_minute':expected_minute,'verified_alarm':len(new)==1 and new[0]['hour']==expected_hour and new[0]['minute']==expected_minute,'existing_alarms_preserved':all(a in after for a in before),'events':events,'before_count':len(before),'after_count':len(after),'independent_live_audit_seconds':audit,'mode':'ready session','setup':setup[-1].strip()}
  (out/'result.json').write_text(json.dumps(result,indent=2));(out/'after.json').write_text(json.dumps(after,indent=2));print(json.dumps({k:v for k,v in result.items() if k!='events'}),flush=True)
  if not result['verified_alarm'] or not result['existing_alarms_preserved']:raise RuntimeError('Alarm was not independently verified')
  if not success:raise RuntimeError('Alarm verified, but controller did not report success; see agent.log')
finally:
 if 'record' in locals() and record.poll() is None:
  record.send_signal(signal.SIGINT);record.wait(timeout=15)
 p.stdin.close()
 try:p.wait(timeout=10)
 except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=5)
