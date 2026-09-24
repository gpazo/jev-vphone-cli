"""Original-speed Contacts recording with separate save and report timings."""
import argparse
import json
import math
from pathlib import Path
import re
import statistics
import subprocess
from PIL import Image, ImageDraw, ImageFont

p=argparse.ArgumentParser(description=__doc__);p.add_argument('recording',type=Path)
root=p.parse_args().recording.resolve();r=json.loads((root/'result.json').read_text())
end=r['agent_seconds'];duration=end+2
calls=[float(x) for x in re.findall(r'timing step \d+ Jev decision: ([0-9.]+) ms',(root/'agent.log').read_text())]
fonts={n:ImageFont.truetype('/System/Library/Fonts/Menlo.ttc',n) for n in [16,18,20,24,30,72]}
w,h=1280,1040;video=root/'jev-contacts-timed.mp4'
offset=r.get('agent_start_video_seconds',0)
proc=subprocess.Popen(['ffmpeg','-y','-hide_banner','-loglevel','error','-i',str(root/'raw.mov'),
    '-f','rawvideo','-pixel_format','rgba','-video_size',f'{w}x{h}','-framerate','10','-i','pipe:0','-filter_complex',
    f'[0:v]fps=30:start_time=0,trim=start={offset:.6f},setpts=PTS-STARTPTS,scale=440:956,tpad=stop_mode=clone:stop_duration=10,trim=duration={duration},pad=1280:1040:30:42:black[base];[base][1:v]overlay=0:0:shortest=1[out]',
    '-map','[out]','-an','-c:v','libx264','-preset','fast','-crf','20','-pix_fmt','yuv420p','-movflags','+faststart',str(video)],stdin=subprocess.PIPE)
actions=[e for e in r['events'] if e['text'].startswith('→')]
try:
    for i in range(math.ceil(duration*10)):
        t=i/10;im=Image.new('RGBA',(w,h),(22,24,28,255));d=ImageDraw.Draw(im);x=520
        d.rectangle((30,42,469,997),fill=(0,0,0,0))
        d.text((x,44),'JEV / APPLE CONTACTS',font=fonts[20],fill='#75DCA9')
        d.text((x,99),'Fill three fields. Save the contact.',font=fonts[24],fill='#F4F5F7')
        d.text((x,150),'Same general controller • No app-specific plan',font=fonts[18],fill='#AEB6C2')
        d.text((x,188),'Native accessibility • No OCR',font=fonts[18],fill='#AEB6C2')
        d.line((x,232,1235,232),fill='#383D45')
        d.text((x,266),'ELAPSED FROM GOAL',font=fonts[18],fill='#AEB6C2')
        d.text((x,300),f'{min(t,end):05.2f} s',font=fonts[72],fill='#F4F5F7')
        d.text((x,410),'INPUT ACKNOWLEDGMENTS / JEV CHOSE LIVE',font=fonts[18],fill='#AEB6C2')
        for j,e in enumerate(actions[-7:]):
            label=re.sub(r'^→\s*\d+\s*','',e['text']).split(' conf')[0]
            d.text((x,450+j*36),f"{e['seconds']:05.2f}s  {label[:51]}",font=fonts[18],fill='#F4F5F7' if t>=e['seconds'] else '#555B66')
        d.line((x,735,1235,735),fill='#383D45')
        if r['verified_saved_contact'] and r['saved'] and t>=r['saved'][0]['seconds']:
            d.text((x,765),f"SAVED + VERIFIED AT {r['saved'][0]['seconds']:.2f}s",font=fonts[24],fill='#75DCA9')
            d.text((x,805),'New record checked independently in SQLite',font=fonts[18],fill='#CBD0D8')
        if t>=end:
            status='Jev completion report' if r['agent_claimed_success'] else 'Jev stopped without completion'
            d.text((x,850),f'{status}: {end:.2f}s',font=fonts[20],fill='#F4F5F7')
        if calls:d.text((x,918),f'{len(calls)} decisions / {statistics.median(calls):.0f} ms median Jev',font=fonts[18],fill='#AEB6C2')
        d.text((x,952),'Ready session; app launch and startup excluded',font=fonts[18],fill='#AEB6C2')
        d.text((30,1010),'One continuous run • Original speed • Independent saved-record audit • 2-second final hold • iOS 26.5',font=fonts[16],fill='#8D97A7')
        proc.stdin.write(im.tobytes())
finally:proc.stdin.close()
if proc.wait():raise RuntimeError('Video render failed')
print(video)
