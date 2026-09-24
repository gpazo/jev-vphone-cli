"""Compare page-scroll mechanics on a fixed web fixture, then native Settings.

No Jev calls or success claims about autonomous navigation. Each trial requires
independent native frames to change and settle; command acknowledgment is separate.
"""
import http.server
import json
import functools
from pathlib import Path
import struct
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests/SafariSearch'))
from record import Reader, page_state

P = 'XC_kAXXCAttribute'

def main():
    devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','booted','--json']))
    ids=[d['udid'] for group in devices['devices'].values() for d in group if d['state']=='Booted']
    if len(ids)!=1: raise RuntimeError('Exactly one booted simulator is required')
    udid=ids[0]
    out = ROOT / 'research/artifacts/jev-native-scroll' / time.strftime('%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    rows = '<meta name="viewport" content="width=device-width,initial-scale=1"><title>Scroll fixture</title><style>body{margin:0}a{height:80px;display:block;border-bottom:1px solid #aaa}</style>' + ''.join(f'<a href="#{i}">Row {i:02}</a>' for i in range(60))
    (out / 'index.html').write_text(rows)
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Quiet, directory=str(out)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    helper = subprocess.Popen(['xcrun', 'simctl', 'spawn', 'booted', str(ROOT / '.tools/axe/JevSimulatorPreferences')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    reader = Reader('booted')
    def native(command):
        helper.stdin.write(json.dumps(command) + '\n'); helper.stdin.flush()
        return json.loads(helper.stdout.readline())
    def request(command):
        payload = json.dumps(command).encode()
        reader.socket.sendall(struct.pack('!I', len(payload)) + payload)
        return json.loads(reader.read(struct.unpack('!I', reader.read(4))[0]))
    def layout(tree):
        result = []
        def walk(node):
            f = node.get(P+'Frame', {})
            label = node.get(P+'Label')
            if label and f:
                result.append((label, round(f['Y']), round(f['Height'])))
            for child in node.get(P+'Children', []): walk(child)
        walk(tree)
        return result
    results = []
    try:
        assert native({'action':'prepare'})['ok']
        for app in ['web', 'settings']:
            methods = ['native', 'hid', 'hid', 'native', 'native', 'hid'] if app == 'web' else ['native', 'native']
            for index, method in enumerate(methods):
                if app == 'web':
                    subprocess.run(['xcrun','simctl','openurl',udid,f'http://127.0.0.1:{server.server_port}/?trial={index}'],check=True,stdout=subprocess.DEVNULL)
                else:
                    subprocess.run(['xcrun','simctl','launch',udid,'com.apple.Preferences'],check=True,stdout=subprocess.DEVNULL)
                deadline = time.monotonic()+12
                while True:
                    tree = reader.tree()
                    ready = page_state(tree)['document_title']=='Scroll fixture' if app=='web' else tree.get(P+'Label')=='Settings'
                    if ready: break
                    if time.monotonic()>deadline: raise RuntimeError('Fixture did not become ready')
                    time.sleep(.1)
                time.sleep(.3)
                for direction in ['down','up']:
                    before = reader.tree(); initial = layout(before)
                    bounds = before[P+'Frame']; x = bounds['Width']/2; y = bounds['Height']/2
                    hit = request({'verb':'hittest','x':x,'y':y})
                    label = hit['tree'][P+'Label']
                    started = time.monotonic()
                    if method == 'native':
                        reply = native({'action':'scroll-'+direction,'x':x,'y':y,'expectedLabel':label})
                    else:
                        near, far = bounds['Height']*.7, bounds['Height']*.3
                        a,b = (near,far) if direction == 'down' else (far,near)
                        command = [str(ROOT/'.tools/axe/axe'),'drag','--start-x',str(x),'--start-y',str(a),'--end-x',str(x),'--end-y',str(b),'--duration','0.6','--udid',udid]
                        p = subprocess.run(command,capture_output=True,text=True)
                        reply = {'ok':p.returncode==0,'stderr':p.stderr}
                    acknowledged = time.monotonic()-started
                    deadline = time.monotonic()+3; previous = None; settled = False
                    while time.monotonic()<deadline:
                        after = reader.tree(); current = layout(after)
                        if current != initial and current == previous:
                            settled = True; break
                        previous = current; time.sleep(.04)
                    elapsed = time.monotonic()-started
                    name = f'{app}-{index}-{method}-{direction}'
                    (out/(name+'-before.json')).write_text(json.dumps(before))
                    (out/(name+'-after.json')).write_text(json.dumps(after))
                    entry = dict(app=app,method=method,direction=direction,command_seconds=acknowledged,settled_seconds=elapsed,changed=current!=initial,settled=settled,reply=reply)
                    results.append(entry); print(json.dumps(entry),flush=True)
                    (out/'result.json').write_text(json.dumps({'trials':results,'complete':False},indent=2))
        # A stale anchor must be rejected without scrolling.
        before=reader.tree(); b=before[P+'Frame']
        reply=native({'action':'scroll-down','x':b['Width']/2,'y':b['Height']/2,'expectedLabel':'not the current control'})
        after=reader.tree()
        stale={'rejected':not reply['ok'],'unchanged':layout(before)==layout(after),'reply':reply}
        (out/'result.json').write_text(json.dumps({'trials':results,'stale_target':stale,'complete':True},indent=2))
        print(out,flush=True)
        assert stale['rejected'] and stale['unchanged']
        assert all(e['reply']['ok'] and e['changed'] and e['settled'] for e in results if e['method']=='native')
    finally:
        reader.close();helper.stdin.close();helper.wait(timeout=5);server.shutdown()

if __name__=='__main__':main()
