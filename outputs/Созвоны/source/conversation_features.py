"""Timestamp links, non-destructive joining, bounded local question retrieval."""
import json,re,hashlib,wave,shutil
from contextlib import nullcontext
from pathlib import Path
from urllib.parse import urlparse,parse_qs
from transcript import write_result

def parse_link(value):
    u=urlparse(value)
    if u.scheme!='calls' or u.netloc!='meeting':raise ValueError('Неподдерживаемая ссылка')
    key=u.path.strip('/')
    if not re.fullmatch(r'[a-fA-F0-9]{16,64}',key):raise ValueError('Некорректный идентификатор разговора')
    try:seconds=float(parse_qs(u.query).get('t',['0'])[0])
    except ValueError:raise ValueError('Некорректный таймкод')
    if not 0<=seconds<=864000:raise ValueError('Некорректный таймкод')
    return key,seconds

def retrieve(segments,question,limit=10000):
    words=set(re.findall(r'[\w]{3,}',question.casefold()))-{'что','как','где','кто','для','это','было','были','какой','какие','когда','чем','про','нам','они'}
    # Simple lexical retrieval keeps context bounded; it is not a full-conversation read.
    scored=[]
    for i,s in enumerate(segments):
        text=s['text'].casefold();score=sum(1 for word in words if word in text or (len(word)>5 and word[:-2] in text))
        if score:scored.append((score,i))
    picked=set()
    for _,i in sorted(scored,reverse=True)[:18]:picked.update(range(max(0,i-1),min(len(segments),i+2)))
    if not picked and sum(len(s['text']) for s in segments)<=limit:picked=set(range(len(segments)))
    rows=[];size=0
    for i in sorted(picked):
        row=f'[{segments[i]["start"]:.2f}] {segments[i]["text"]}'
        if size+len(row)>limit:break
        rows.append(row);size+=len(row)
    return '\n'.join(rows),[dict(start=segments[i]['start'],text=segments[i]['text']) for i in sorted(picked) if any(row.startswith(f'[{segments[i]["start"]:.2f}]') for row in rows)]

def join_recordings(j,parts,run,update,cancelled,lock=None,name_recording=None):
    stage=Path(j['staging']);dest=Path(j['destination'])
    if dest.is_dir():
        marker=dest/'.calls-result.json'
        if marker.is_file() and json.loads(marker.read_text()).get('id')==j['id']:
            j.pop('kind',None);j.pop('locations',None);update(j,path=str(dest/'.playback.m4a'),output=str(dest),status='done',progress=100,message='Объединение восстановлено');return
        raise ValueError('Папка результата уже существует')
    if stage.exists():
        # Only the app-owned staging path is eligible for restart cleanup.
        if stage.name!='.merge-'+j['id']:raise ValueError('Некорректная временная папка')
        shutil.rmtree(stage)
    stage.mkdir(parents=True,exist_ok=False)
    try:
        segments=[];offset=0.;manifest=[];wav=stage/'.joined.wav'
        with wave.open(str(wav),'wb') as output:
            output.setnchannels(1);output.setsampwidth(2);output.setframerate(16000)
            for i,part in enumerate(parts):
                folder=Path(part['output']);raw=(folder/'.segments.json').read_bytes()
                if hashlib.sha256(raw).hexdigest()!=part['revision']:raise ValueError('Один из транскриптов изменился. Создай объединение заново.')
                data=json.loads(raw);audio=folder/'.playback.m4a'
                if not audio.is_file():audio=Path(part['path'])
                update(j,status='converting',message=f'Объединяем часть {i+1} из {len(parts)}',progress=i*80/len(parts))
                piece=stage/f'.part-{i}.wav'
                run(['-nostdin','-y','-i',audio,'-vn','-ac','1','-ar','16000','-c:a','pcm_s16le',piece],j)
                with wave.open(str(piece),'rb') as source:
                    duration=source.getnframes()/source.getframerate()
                    while True:
                        block=source.readframes(16000*10)
                        if not block:break
                        output.writeframesraw(block)
                for s in data:
                    if s['start']<=duration:segments.append(dict(start=offset+s['start'],end=offset+min(s['end'],duration),text=s['text']))
                manifest.append(dict(id=part['id'],title=part['title'],start=offset,duration=duration));offset+=duration;piece.unlink()
        if not segments:raise ValueError('В частях нет текста')
        run(['-nostdin','-y','-i',wav,'-c:a','aac','-b:a','128k',stage/'.playback.m4a'],j);wav.unlink()
        if j['id'] in cancelled:raise InterruptedError()
        if name_recording:
            update(j,status='naming',message='Подбираем название объединённой встречи',progress=90)
            title,note=name_recording('\n'.join(s['text'] for s in segments),Path('Объединённый разговор'),j)
            if note:raise ValueError('Не удалось создать название объединённой встречи: '+note)
            title=re.sub(r'^объедин[её]нный\s*[—:–-]?\s*','',title,flags=re.I)
            title='Объединённый — '+title
            dest=dest.parent/(dest.name[:10]+' — '+title[:140]+' — '+j['id'][:6])
            update(j,title=title,name=title,destination=str(dest))
        write_result(stage,j['title'],segments,'.playback.m4a')
        (stage/'.parts.json').write_text(json.dumps(manifest,ensure_ascii=False))
        (stage/'.calls-result.json').write_text(json.dumps({'id':j['id'],'kind':'merged','title':j['title'],'parts':manifest},ensure_ascii=False))
        for part in parts:
            if hashlib.sha256((Path(part['output'])/'.segments.json').read_bytes()).hexdigest()!=part['revision']:raise ValueError('Текст части изменился во время объединения')
        with lock if lock is not None else nullcontext():
            if j['id'] in cancelled:raise InterruptedError()
            stage.rename(dest)
            j.pop('kind',None);j.pop('locations',None)
            update(j,path=str(dest/'.playback.m4a'),output=str(dest),status='done',progress=100,message='Части объединены · исходники сохранены')
    except BaseException:
        shutil.rmtree(stage,ignore_errors=True);raise
