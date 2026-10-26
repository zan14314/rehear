import sys,tempfile,wave,time
from pathlib import Path
sys.path.insert(0,str(Path('outputs/Rehear/source').resolve()))
from transcription_guard import suspicious,recover,check,srt_text
from transcript import parse_srt

def seg(a,b,t):return dict(start=a,end=b,text=t)
normal=[seg(i,i+1,'Да.' if i%2==0 else f'Тема {i}') for i in range(60)]
assert not suspicious(normal)
assert not suspicious([seg(i,i+1,'Да.') for i in range(3)])
loop=[seg(i,i+1,'Штраф за опоздание.') for i in range(10,210)]
assert suspicious(loop)==[(10,210)]
assert suspicious([seg(0,20,'Повторяется одна фраза. '*20)])
assert suspicious([seg(i,i+1,['Первое слово.','Второе слово.'][i%2]) for i in range(20)])
with tempfile.TemporaryDirectory() as td:
 wav=Path(td)/'audio.wav'
 with wave.open(str(wav),'wb') as out:
  out.setparams((1,2,16000,0,'NONE','not compressed'));out.writeframes(b'\0\0'*(16000*220))
 calls=[]
 def retry(clip):
  with wave.open(str(clip),'rb') as f:duration=f.getnframes()/f.getframerate()
  calls.append(duration)
  return [seg(i,min(duration,i+3),f'Другая фраза номер {len(calls)} {i}.') for i in range(0,int(duration),3)]
 initial=[seg(0,10,'Нормальное начало.')]+loop+[seg(210,220,'Нормальное окончание.')]
 fixed=recover(wav,initial,retry)
 assert fixed[0]==initial[0] and fixed[-1]==initial[-1]
 assert len(calls)==3 and max(calls)<=94 and not suspicious(fixed)
 assert parse_srt(srt_text(fixed))==fixed
 calls.clear();assert recover(wav,normal,retry)==normal and not calls
 try:recover(wav,loop,lambda clip:[seg(i,i+1,'Штраф за опоздание.') for i in range(90)]);raise AssertionError('persistent loop accepted')
 except ValueError:pass
print('PASS no work for normal speech; repeated/pattern/in-segment loops; bounded recovery; unchanged good regions; SRT roundtrip; persistent failures surfaced')
# Existing corrupted full-length result is caught cheaply, without model calls.
import json
segments=[seg(114.6+i,115.6+i,'Штраф за опоздание.') for i in range(4200)];started=time.monotonic();spans=suspicious(segments)
assert spans and spans[0][0]<116 and spans[-1][1]>4200
print('PASS long fixed repetition fixture detected in',round((time.monotonic()-started)*1000,1),'ms')
from transcription_guard import windows,combine_windows
with tempfile.TemporaryDirectory() as td:
 wav=Path(td)/'source.wav'
 with wave.open(str(wav),'wb') as out:
  out.setparams((1,2,16000,0,'NONE','not compressed'));out.writeframes(b'\0\0'*(16000*250))
 parts=windows(wav);assert len(parts)==3 and parts[1][3]==118
 for path,start,end,offset in parts:
  with wave.open(str(path),'rb') as audio:assert audio.getnframes()/audio.getframerate()<=124
 combined=combine_windows(parts,lambda p:[seg(3,4,p.name)])
 assert [s['start'] for s in combined]==[3,121,241]
print('PASS independent 2min windows, bounded overlap, original absolute timestamps')
