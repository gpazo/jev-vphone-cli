"""Live reference guards on the open Settings > Display & Text Size pane.

This test toggles Bold Text and restores its original native value. The
controller is not involved; a separate AX reader verifies actual UI state.
"""
import json
from pathlib import Path
import subprocess
import time

from check import P, ROOT, Reader, tree, walk


def main():
    reader = Reader('booted')
    helper = ROOT/'.tools/axe/JevSimulatorPreferences'
    process = subprocess.Popen(['xcrun','simctl','spawn','booted',str(helper)],
                               stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
    out = ROOT/'research/artifacts/jev-native-validation'/time.strftime('%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    def send(command):
        process.stdin.write(json.dumps(command)+'\n');process.stdin.flush()
        return json.loads(process.stdout.readline())
    def node():
        found = [n for n in walk(tree(reader)) if n.get(P+'AutomationType')==40 and n.get(P+'Label')=='Bold Text']
        if len(found)!=1:raise RuntimeError('Open Display & Text Size before running this test')
        return found[0]
    def point(n):
        f=n[P+'Frame'];return dict(x=f['X']+f['Width']/2,y=f['Y']+f['Height']/2)
    before = node()[P+'Value']; checks = []
    def capture():
        return send(dict(action='capture-targets',points=[point(node())]))['targets'][0]['token']
    def press():return dict(action='press',expectedLabel='Bold Text',**point(node()))
    def await_value(value):
        for _ in range(20):
            if node()[P+'Value']==value:return
            time.sleep(.05)
        raise AssertionError('Native switch did not reach the expected value')
    try:
        token=capture();assert send(dict(action='validate-target',token=token))['ok']
        checks.append('unchanged native control accepted')
        assert not send(dict(action='validate-target',token=token+'invalid'))['ok']
        checks.append('malformed token rejected')
        fresh=capture();assert not send(dict(action='validate-target',token=token))['ok']
        checks.append('previous observation rejected')
        subprocess.run(['xcrun','simctl','spawn','booted',str(helper)],
                       input=json.dumps(press())+'\n',text=True,capture_output=True,check=True)
        await_value('1' if before=='0' else '0')
        assert not send(dict(action='validate-target',token=fresh))['ok']
        checks.append('changed value rejected')
        token=capture();command=dict(press(),expectedToken=token)
        assert send(command)['ok'];await_value(before)
        checks.append('guarded press restored native state')
        assert not send(command)['ok'];await_value(before)
        checks.append('consumed input decision rejected without a second mutation')
        (out/'result.json').write_text(json.dumps(dict(checks=checks,passed=True,original_value=before),indent=2))
        print(out);print(json.dumps(checks))
    finally:
        try:
            if node()[P+'Value']!=before:
                assert send(press())['ok'];await_value(before)
        finally:
            process.stdin.close();process.wait(timeout=5);reader.close()


if __name__=='__main__':main()
