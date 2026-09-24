"""Read-only native-target feasibility measurement on the current screen.

Build Probe.m for iphonesimulator first. This is not a controller fast path:
ancestry alone has not proved equivalent modal/document/context semantics.
"""
import argparse
import json
from pathlib import Path
import statistics
import struct
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests/SafariSearch'))
from record import Reader

P = 'XC_kAXXCAttribute'
ATTRIBUTES = ['ElementType', 'ElementBaseType', 'Label', 'Value', 'Identifier',
              'Frame', 'AutomationType', 'Children', 'PlaceholderValue']


def tree(reader):
    request = dict(verb='describe', method='window-server', x=0, y=0,
                   snapshotTree=True, automationMode=True, maxNodes=20000,
                   attributes=[P + key for key in ATTRIBUTES])
    data = json.dumps(request).encode()
    reader.socket.sendall(struct.pack('!I', len(data)) + data)
    result = json.loads(reader.read(struct.unpack('!I', reader.read(4))[0]))
    if not result.get('ok') or result.get('truncated'):
        raise RuntimeError(result)
    return result['tree']


def walk(node):
    yield node
    for child in node.get(P + 'Children', []):
        yield from walk(child)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('label')
    parser.add_argument('--type', type=int, required=True)
    parser.add_argument('--probe', default='/tmp/jev-native-validation-probe')
    parser.add_argument('--repeats', type=int, default=10)
    parser.add_argument('--batch', action='store_true', help='Measure ancestry capture for all visible controls')
    args = parser.parse_args()
    out = ROOT / 'research/artifacts/jev-native-validation' / time.strftime('%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    reader = Reader('booted')
    helper = subprocess.Popen(['xcrun', 'simctl', 'spawn', 'booted', args.probe],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    def send(command):
        start = time.monotonic()
        helper.stdin.write(json.dumps(command) + '\n'); helper.stdin.flush()
        reply = json.loads(helper.stdout.readline())
        return reply, (time.monotonic() - start) * 1000
    try:
        before = tree(reader)
        matches = [n for n in walk(before) if n.get(P + 'AutomationType') == args.type
                   and args.label in (n.get(P + 'Label'), n.get(P + 'PlaceholderValue'))]
        if len(matches) != 1:
            raise RuntimeError(f'Expected unique target, got {len(matches)}')
        frame = matches[0][P + 'Frame']
        point = dict(x=frame['X'] + frame['Width']/2, y=frame['Y'] + frame['Height']/2)
        points = []
        for node in walk(before):
            f = node.get(P + 'Frame', {})
            x, y = f.get('X', 0) + f.get('Width', 0)/2, f.get('Y', 0) + f.get('Height', 0)/2
            if node.get(P + 'AutomationType') in (9, 10, 39, 40, 42, 44, 45, 49, 50, 52):
                if 0 < x < 402 and 0 < y < 874 and dict(x=x, y=y) not in points:
                    points.append(dict(x=x, y=y))
        if args.batch and point not in points:
            points.append(point)
        capture, cold = send(dict(op='capture', **point))
        if not capture['ok']:
            raise RuntimeError(capture)
        trials = []
        for _ in range(args.repeats):
            start = time.monotonic(); tree(reader)
            full_ms = (time.monotonic() - start) * 1000
            captured, capture_ms = send(dict(op='capture-many', points=points) if args.batch else dict(op='capture', **point))
            checked, validate_ms = send(dict(op='validate', index=points.index(point)) if args.batch else dict(op='validate'))
            trials.append(dict(full_tree_ms=full_ms, capture_ms=capture_ms,
                               validate_ms=validate_ms, capture=captured['ok'], validation=checked))
        result = dict(label=args.label, batch=args.batch, points=points, cold_capture_ms=cold, chain=capture['chain'], trials=trials,
                      medians={k:statistics.median(t[k] for t in trials)
                               for k in ('full_tree_ms', 'capture_ms', 'validate_ms')})
        (out / 'result.json').write_text(json.dumps(result, indent=2))
        (out / 'before.json').write_text(json.dumps(before))
        print(out); print(json.dumps(result['medians']))
        if not all(t['capture'] and t['validation']['ok'] for t in trials):
            raise RuntimeError('Unchanged target failed validation')
    finally:
        reader.close(); helper.stdin.close(); helper.wait(timeout=5)


if __name__ == '__main__':
    main()
