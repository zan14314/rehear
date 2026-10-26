"""Cheap loop detection and bounded, isolated recovery. Never delete repeated speech."""
import re,wave,math,array
from pathlib import Path
from transcript import parse_srt

def normalized(text):return ' '.join(re.findall(r'\w+',text.casefold()))
def suspicious(segments):
    keys=[normalized(s['text']) for s in segments];found=[];n=len(keys)
    for period in range(1,5):
        i=0
        while i+period*6<=n:
            pattern=keys[i:i+period]
            if not all(pattern):i+=1;continue
            end=i+period
            while end<n and keys[end]==pattern[(end-i)%period]:end+=1
            if end-i>=period*6 and segments[end-1]['end']-segments[i]['start']>=6:
                found.append((segments[i]['start'],segments[end-1]['end']));i=end
            else:i+=1
    # Whisper can also put an entire loop inside a single subtitle.
    for s,key in zip(segments,keys):
        words=key.split()
        if any(all(words[i:i+p]==words[i+p*k:i+p*(k+1)] for k in range(1,6))
               for p in range(2,min(17,len(words)//6+1)) for i in range(max(0,len(words)-p*6+1))):
            found.append((s['start'],s['end']))
    merged=[]
    for a,b in sorted(found):
        if merged and a<=merged[-1][1]+2:merged[-1]=(merged[-1][0],max(b,merged[-1][1]))
        else:merged.append((a,b))
    return merged

def sparse_audio(wav,segments,parts=None):
    """Verify only unusually sparse windows; sustained audio is evidence to retry,
    not evidence that the first decoded words are correct. No model call here.
    """
    found=[]
    with wave.open(str(wav),'rb') as audio:
        rate=audio.getframerate();duration=audio.getnframes()/rate
        if audio.getnchannels()!=1 or audio.getsampwidth()!=2:return found
        spans=[(a,b) for _,a,b,_ in parts] if parts else [(0,duration)]
        for a,b in spans:
            count=sum(len(normalized(s['text']).split()) for s in segments if a<=(s['start']+s['end'])/2<b)
            if b-a<12 or count>max(8,(b-a)*0.45):continue
            audio.setpos(min(audio.getnframes(),round(a*rate)));loud=total=0
            remaining=round((b-a)*rate)
            while remaining>0:
                samples=array.array('h',audio.readframes(min(remaining,rate//2)))
                if not samples:break
                remaining-=len(samples);total+=1
                # Sample every 16th frame: negligible cost even on a long file.
                values=samples[::16]
                loud+=sum(v*v for v in values)/max(1,len(values))>(32768*0.003)**2
            if total and loud/total>=0.4:found.append((a,b))
    return found

def check(segments):
    spans=suspicious(segments)
    if spans:
        a,b=spans[0]
        def stamp(t):return f'{int(t)//60:02d}:{int(t)%60:02d}'
        raise ValueError(f'Подозрение на зацикливание речи · {stamp(a)}–{stamp(b)}. Нужно повторное распознавание записи; саммари и абзацы пока недоступны.')

def srt_text(segments):
    def stamp(t):
        ms=max(0,round(t*1000));return f'{ms//3600000:02d}:{ms//60000%60:02d}:{ms//1000%60:02d},{ms%1000:03d}'
    return '\n\n'.join(f'{i+1}\n{stamp(s["start"])} --> {stamp(s["end"])}\n{s["text"]}' for i,s in enumerate(segments))+'\n'

def recover(wav,segments,recognize,progress=lambda *args:None,spans=None):
    spans=suspicious(segments) if spans is None else spans
    if not spans:return segments
    with wave.open(str(wav),'rb') as audio:
        rate=audio.getframerate();duration=audio.getnframes()/rate
        # Include whole affected segments: replacement never leaves half a sentence.
        spans=[(max(0,a),min(duration,b)) for a,b in spans]
        result=[s for s in segments if not any(s['start']<b and s['end']>a for a,b in spans)]
        total=sum(math.ceil((b-a)/90) for a,b in spans);done=0
        for a,b in spans:
            start=a
            while start<b:
                end=min(b,start+90);lo=max(0,start-2);hi=min(duration,end+2)
                clip=Path(wav).with_name('recovery.wav')
                audio.setpos(round(lo*rate))
                with wave.open(str(clip),'wb') as out:
                    out.setparams(audio.getparams());out.writeframes(audio.readframes(round((hi-lo)*rate)))
                progress(done,total,start,end)
                fresh=recognize(clip)
                if not fresh:raise ValueError(f'Повторное распознавание не вернуло речь на {start:.0f}–{end:.0f} с; результат не заменён')
                for s in fresh:
                    t=dict(s,start=s['start']+lo,end=s['end']+lo)
                    if start<=(t['start']+t['end'])/2<end:
                        t['start']=max(a,t['start']);t['end']=min(b,t['end']);result.append(t)
                done+=1;start=end
    result.sort(key=lambda s:(s['start'],s['end']))
    check(result) # One recovery pass only; persistent loops are surfaced, never hidden.
    return result

def windows(wav,seconds=120,padding=2):
    """Small PCM copies; decoder consumes every file in one model session."""
    with wave.open(str(wav),'rb') as audio:
        rate=audio.getframerate();duration=audio.getnframes()/rate
        if duration<=seconds:return [(Path(wav),0,duration,0)]
        result=[];start=0
        while start<duration:
            end=min(duration,start+seconds);lo=max(0,start-padding);hi=min(duration,end+padding)
            path=Path(wav).with_name(f'window-{len(result):05d}.wav');audio.setpos(round(lo*rate))
            with wave.open(str(path),'wb') as out:
                out.setparams(audio.getparams());out.writeframes(audio.readframes(round((hi-lo)*rate)))
            result.append((path,start,end,lo));start=end
        return result

def combine_windows(parts,read):
    result=[]
    for path,start,end,offset in parts:
        for s in read(path):
            a=s['start']+offset;b=s['end']+offset
            if start<=(a+b)/2<end:result.append(dict(s,start=max(0,a),end=b))
    return sorted(result,key=lambda s:(s['start'],s['end']))
