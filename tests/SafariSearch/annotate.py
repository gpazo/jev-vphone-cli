"""Render a Safari evaluation at original speed with measured milestones."""
import argparse
import json
import math
from pathlib import Path
import re
import statistics
import subprocess
from PIL import Image, ImageDraw, ImageFont

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('recording',type=Path)
a=p.parse_args();root=a.recording.resolve()
r=json.loads((root/'result.json').read_text());end=r['agent_seconds']
verified_at=max((read['seconds'] for read in r.get('audit_reads',[]) if read.get('final')),default=end)
offset=r.get('agent_start_video_seconds',0)
duration=max(end,verified_at,max((m['seconds'] for m in r['milestones']),default=0))+2
fonts={n:ImageFont.truetype('/System/Library/Fonts/Menlo.ttc',n) for n in [16,18,20,24,32,76]}
query=r['goal'].split('"')[1]
ranked=r['ranked_results'];labels=['Google results',
 'First: '+(ranked[0]['host'] if ranked else 'unknown'), 'Back to Google',
 'Second: '+(ranked[1]['host'] if len(ranked)>1 else 'unknown')]
steps=list(zip(labels,r['milestones']))
calls=[float(v) for v in re.findall(r'timing step \d+ Jev decision: ([0-9.]+) ms',(root/'agent.log').read_text())]
w,h=1280,1040;video=root/'jev-safari-timed.mp4'
# Fill sparse simulator frames before trimming: an input seek otherwise drops
# the frame held across goal time and can start the output hundreds of ms late.
cmd=['ffmpeg','-y','-hide_banner','-loglevel','error','-i',str(root/'raw.mov'),
 '-f','rawvideo','-pixel_format','rgba','-video_size',f'{w}x{h}','-framerate','10','-i','pipe:0',
 '-filter_complex',f'[0:v]fps=30:start_time=0,trim=start={offset:.6f},setpts=PTS-STARTPTS,scale=440:956,tpad=stop_mode=clone:stop_duration=10,trim=duration={duration},pad=1280:1040:30:42:black[base];[base][1:v]overlay=0:0:shortest=1[out]',
 '-map','[out]','-an','-c:v','libx264','-preset','fast','-crf','20','-pix_fmt','yuv420p','-movflags','+faststart',str(video)]
proc=subprocess.Popen(cmd,stdin=subprocess.PIPE)
try:
 for i in range(math.ceil(duration*10)):
  t=i/10;im=Image.new('RGBA',(w,h),(22,24,28,255));d=ImageDraw.Draw(im);x=520
  d.rectangle((30,42,469,997),fill=(0,0,0,0))
  d.text((x,44),'JEV / SAFARI',font=fonts[20],fill='#75DCA9')
  d.text((x,99),'Search → first → Back → second',font=fonts[24],fill='#F4F5F7')
  d.text((x,149),f'Google: {query}',font=fonts[18],fill='#AEB6C2')
  d.text((x,187),'Native accessibility • No OCR',font=fonts[18],fill='#AEB6C2')
  d.line((x,232,1235,232),fill='#383D45')
  d.text((x,266),'ELAPSED FROM GOAL',font=fonts[18],fill='#AEB6C2')
  d.text((x,300),f'{min(t,end):05.2f} s',font=fonts[76],fill='#F4F5F7')
  d.text((x,421),'INDEPENDENTLY OBSERVED MILESTONES',font=fonts[18],fill='#AEB6C2')
  for j,(label,m) in enumerate(steps):
   d.text((x,466+j*45),f"{m['seconds']:05.2f}s  {label}",font=fonts[20],fill='#F4F5F7' if t>=m['seconds'] else '#555B66')
  if calls:d.text((x,687),f'{len(calls)} decisions / {statistics.median(calls):.0f} ms median Jev call',font=fonts[18],fill='#AEB6C2')
  d.text((x,723),'General controller; results chosen live',font=fonts[18],fill='#AEB6C2')
  d.line((x,775,1235,775),fill='#383D45')
  if t>=verified_at:
   passed=r['verified_sequence']
   clean=passed and r.get('verified_stop_after_second_page',False)
   status='SEQUENCE + STOP VERIFIED' if clean else ('SEQUENCE ONLY / EXTRA INPUT' if passed and r.get('actions_started_after_second_page') else 'SEQUENCE NOT VERIFIED')
   d.text((x,807),status,font=fonts[24],fill='#75DCA9' if clean else '#EFC578')
   claim='complete' if r['agent_claimed_success'] else 'stopped'
   d.text((x,849),f'Jev: {claim} ({end:.2f}s) / audit: {verified_at:.2f}s',font=fonts[18],fill='#CBD0D8')
  elif t>=end:
   d.text((x,807),'FINAL INDEPENDENT CHECK',font=fonts[24],fill='#EFC578')
   d.text((x,849),'Jev reported completion' if r['agent_claimed_success'] else 'Jev stopped without completion',font=fonts[18],fill='#CBD0D8')
  else:d.text((x,808),'Jev selects; code checks and executes.',font=fonts[20],fill='#CBD0D8')
  d.text((x,917),'Ready session starts on example.com',font=fonts[18],fill='#AEB6C2')
  d.text((x,952),'Session startup excluded; browsing included',font=fonts[18],fill='#AEB6C2')
  d.text((30,1010),'One continuous run • Original speed • Separate read-only audit • 2-second final hold • iOS 26.5',font=fonts[16],fill='#8D97A7')
  proc.stdin.write(im.tobytes())
finally:proc.stdin.close()
if proc.wait():raise RuntimeError('Video render failed')
print(video)
