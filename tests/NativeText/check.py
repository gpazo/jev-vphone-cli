"""Live native text-input contract checks in Safari, independent of Jev.

This exercises Safari’s native address editor, not an autonomous-task demo.
Each write is checked through a separate native accessibility connection.
"""
import json
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests/SafariSearch'))
from record import Reader

P = 'XC_kAXXCAttribute'


def main():
    out = ROOT / 'research/artifacts/jev-native-text' / time.strftime('%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    helper = subprocess.Popen(['xcrun', 'simctl', 'spawn', 'booted', str(ROOT / '.tools/axe/JevSimulatorPreferences')],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    reader = Reader('booted')
    def native(command):
        helper.stdin.write(json.dumps(command) + '\n'); helper.stdin.flush()
        return json.loads(helper.stdout.readline())
    def elements():
        result = []
        def walk(node):
            if node.get(P+'Label'): result.append(node)
            for child in node.get(P+'Children', []): walk(child)
        walk(reader.tree())
        return result
    def field(label, types=(49, 50, 52)):
        matches = [n for n in elements() if n[P+'Label'] == label and n.get(P+'AutomationType') in types]
        if len(matches) != 1: raise RuntimeError(f'Expected one {label}: {len(matches)}')
        return matches[0]
    def replace(label, text, expected_label=None, expected_value=None, types=(49, 50, 52)):
        node = field(label, types); f = node[P+'Frame']
        command = {'action': 'replace-text', 'x': f['X']+f['Width']/2, 'y': f['Y']+f['Height']/2,
            'expectedLabel': expected_label or label, 'text': text}
        if expected_value is not None: command['expectedValue'] = expected_value
        started = time.monotonic(); reply = native(command)
        return reply, time.monotonic()-started
    trials = []
    try:
        assert native({'action': 'prepare'})['ok']
        subprocess.run(['xcrun', 'simctl', 'launch', 'booted', 'com.apple.mobilesafari'], check=True)
        address = [n for n in elements() if n[P+'Label'] == 'Address'][0]
        if address.get(P+'AutomationType') != 49:
            f = address[P+'Frame']
            assert native({'action': 'press', 'x': f['X']+f['Width']/2, 'y': f['Y']+f['Height']/2,
                'expectedLabel': 'Address'})['ok']
        deadline = time.monotonic()+15
        while True:
            try:
                field('Address'); break
            except RuntimeError:
                if time.monotonic() > deadline: raise
                time.sleep(.1)
        for label, text in [('Address', 'Café 你好'), ('Address', 'native accessibility test')]:
            reply, elapsed = replace(label, text)
            observed = field(label)[P+'Value']
            trials.append(dict(label=label, reply=reply, seconds=elapsed, observed=observed))
            assert reply.get('ok') and reply.get('value') == text and observed == text
        for label, expected, value, types in [('Address', 'Wrong field', None, (49,)),
                ('Address', None, 'Stale value', (49,)), ('Clear text', None, None, (9,))]:
            before = [(n[P+'Label'], n.get(P+'Value')) for n in elements() if n.get(P+'AutomationType') in (49, 50, 52)]
            reply, elapsed = replace(label, 'Must not be written', expected, value, types)
            after = [(n[P+'Label'], n.get(P+'Value')) for n in elements() if n.get(P+'AutomationType') in (49, 50, 52)]
            trials.append(dict(label=label, reply=reply, seconds=elapsed, unchanged=before == after))
            assert not reply.get('ok') and before == after
        (out / 'result.json').write_text(json.dumps({'passed': True, 'trials': trials}, indent=2))
        print(out)
    finally:
        reader.close(); helper.stdin.close(); helper.wait(timeout=5)


if __name__ == '__main__': main()
