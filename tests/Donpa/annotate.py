"""Add an original-speed timer and evidence panel to a recorded Donpa attempt."""
import argparse, json, math, subprocess, textwrap
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('recording',type=Path)
a=p.parse_args();root=a.recording.resolve()
r=json.loads((root/'result.json').read_text())
end=r['agent_seconds'];duration=end+2
font='/System/Library/Fonts/Menlo.ttc'
fonts={s:ImageFont.truetype(font,s) for s in [16,18,20,24,32,76]}
w,h=1280,1040;video=root/'jev-donpa-timed.mp4'
cmd=['ffmpeg','-y','-hide_banner','-loglevel','error','-i',str(root/'raw.mov'),
     '-f','rawvideo','-pixel_format','rgba','-video_size',f'{w}x{h}','-framerate','10','-i','pipe:0',
     '-filter_complex',f'[0:v]fps=30,scale=440:956,tpad=stop_mode=clone:stop_duration=10,trim=duration={duration},pad=1280:1040:30:42:black[base];[base][1:v]overlay=0:0:shortest=1[out]',
     '-map','[out]','-an','-c:v','libx264','-preset','fast','-crf','20','-pix_fmt','yuv420p','-movflags','+faststart',str(video)]
process=subprocess.Popen(cmd,stdin=subprocess.PIPE)
try:
 for i in range(math.ceil(duration*10)):
  t=i/10;im=Image.new('RGBA',(w,h),(22,24,28,255));d=ImageDraw.Draw(im);x=520
  d.rectangle((30,42,469,997),fill=(0,0,0,0))
  d.text((x,44),'JEV / PHONE CONTROL',font=fonts[20],fill='#75DCA9')
  d.text((x,90),'Donpa Squad / Minesweeper',font=fonts[32],fill='#F4F5F7')
  d.text((x,143),'Existing game, unchanged • iOS 26.5',font=fonts[18],fill='#AEB6C2')
  d.text((x,177),'Native accessibility text and named actions',font=fonts[18],fill='#AEB6C2')
  d.line((x,224,1235,224),fill='#383D45')
  d.text((x,250),'ELAPSED FROM GOAL / SESSION READY',font=fonts[18],fill='#AEB6C2')
  d.text((x,284),f'{min(t,end):05.2f} s',font=fonts[76],fill='#F4F5F7')
  actions=[e for e in r['events'] if e['seconds']<=t and '→' in e['text']]
  d.text((x,393),'LATEST CONTROLLER ACTIONS',font=fonts[18],fill='#AEB6C2')
  y=432
  for event in actions[-4:]:
   label=event['text'].split('→',1)[1].strip()
   for line in textwrap.wrap(f"{event['seconds']:05.2f}s  {label}",width=57)[:2]:
    d.text((x,y),line,font=fonts[18],fill='#F1F3F6');y+=27
   y+=8
  snapshots=[e for e in r['timeline'] if e['seconds']<=t]
  if snapshots:
   board=next((e for e in snapshots[-1]['elements'] if e['label']=='Board'),None)
   if board and board.get('value'):
    d.text((x,698),'INDEPENDENT BOARD OBSERVATION',font=fonts[18],fill='#AEB6C2')
    for j,line in enumerate(textwrap.wrap(board['value'],width=57)[:2]):
     d.text((x,733+j*27),line,font=fonts[18],fill='#F1F3F6')
  d.line((x,810,1235,810),fill='#383D45')
  if t>=end:
   outcome=r['game_outcome'].upper()
   d.text((x,837),f'OBSERVED RESULT: {outcome}',font=fonts[24],fill='#75DCA9' if outcome=='WON' else '#EFC578')
   claim='complete' if r['agent_claimed_success'] else 'stopped without completion'
   d.text((x,884),f'Jev: {claim}',font=fonts[18],fill='#CBD0D8')
  else:
   d.text((x,842),'Jev selects; code executes.',font=fonts[20],fill='#CBD0D8')
   d.text((x,884),'No OCR • No hidden board or solver input',font=fonts[18],fill='#AEB6C2')
  d.text((x,940),'Build and session startup excluded from timer',font=fonts[16],fill='#8D97A7')
  d.text((30,1010),'One continuous run • Original speed • Separate read-only audit • Final frame held for 2 seconds',font=fonts[16],fill='#8D97A7')
  process.stdin.write(im.tobytes())
finally:
 process.stdin.close()
code=process.wait()
if code:raise RuntimeError(f'ffmpeg exited {code}')
print(video)
