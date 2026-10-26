"""Local transcript search and reversible, version-checked text corrections."""
import hashlib,json,shutil,uuid
from pathlib import Path
from transcript import write_result

def revision(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def search(jobs,query):
    query=query.strip();hits=[]
    if not query:return hits
    needle=query.casefold()
    for job in jobs:
        if job.get('status')!='done' or job.get('kind') in ('summary','paragraphs','qa','improve'):continue
        title=job.get('title') or job['name'];folder=Path(job.get('output') or '/nonexistent')
        matches=[]
        try:segments=json.loads((folder/'.segments.json').read_text())
        except (OSError,ValueError):segments=[]
        for segment in segments:
            text=segment['text'];at=text.casefold().find(needle)
            if at<0:continue
            # Keep the full matching sentence; the native UI highlights the query.
            matches.append(dict(jobId=job['id'],title=title,start=segment['start'],text=text))
        if needle in title.casefold() or needle in job['name'].casefold() or needle in Path(job['path']).name.casefold():
            hits.append(dict(jobId=job['id'],title=title,start=None,text='Совпадение в названии'))
        hits.extend(matches)
    return hits

def edit(job,expected,start,text,find='',replacement='',restore=False,history_action=None):
    folder=Path(job['output']);segments_file=folder/'.segments.json'
    if revision(segments_file)!=expected:raise ValueError('Текст уже изменился. Закрой редактор и открой его снова.')
    segments=json.loads(segments_file.read_text());versions=folder/'.text-versions';versions.mkdir(exist_ok=True)
    history_file=folder/'.text-history.json'
    try:history=json.loads(history_file.read_text())
    except FileNotFoundError:history={'undo':[p.name for p in sorted(versions.iterdir(),key=lambda p:p.stat().st_mtime_ns) if p.is_dir()],'redo':[]}
    action=history_action or ('undo' if restore else None)
    if action:
        if action not in ('undo','redo'):raise ValueError('Неизвестное действие истории')
        stack=history[action]
        if not stack:raise ValueError('Нет правок для отмены' if action=='undo' else 'Нет правок для повтора')
        segments=json.loads((versions/stack[-1]/'.segments.json').read_text())
    elif find:
        count=0
        for segment in segments:
            count+=segment['text'].count(find);segment['text']=segment['text'].replace(find,replacement)
        if not count:raise ValueError('Точное совпадение для замены не найдено')
    else:
        match=next((s for s in segments if s['start']==start),None)
        if match is None:raise ValueError('Фрагмент не найден')
        if not text.strip():raise ValueError('Текст фрагмента не должен быть пустым')
        match['text']=text.strip()
    texts=[p for p in folder.glob('*.txt') if p.name not in ('Краткое содержание.txt','Сплошной текст.txt')]
    if not texts:raise ValueError('TXT транскрипта не найден')
    base=texts[0].stem;targets=[segments_file,folder/(base+'.txt'),folder/(base+'.html'),folder/'.subtitles.srt',folder/'Сплошной текст.txt',folder/'.plain-meta.json']
    backup=versions/uuid.uuid4().hex;backup.mkdir()
    for path in targets:
        if path.is_file():shutil.copy2(path,backup/path.name)
    try:
        write_result(folder,base,segments,'.playback.m4a')
        def stamp(value):
            n=round(value*1000);return f'{n//3600000:02d}:{n//60000%60:02d}:{n//1000%60:02d},{n%1000:03d}'
        subtitle=folder/'.subtitles.srt';temp=subtitle.with_suffix('.tmp')
        temp.write_text('\n\n'.join(f'{i+1}\n{stamp(segment["start"])} --> {stamp(segment["end"])}\n{segment["text"]}' for i,segment in enumerate(segments))+'\n',encoding='utf-8');temp.replace(subtitle)
        if action:
            history[action].pop();history['redo' if action=='undo' else 'undo'].append(backup.name)
        else:history['undo'].append(backup.name);history['redo']=[]
        temp_history=history_file.with_suffix('.tmp');temp_history.write_text(json.dumps(history));temp_history.replace(history_file)
    except Exception:
        for path in targets:
            if (backup/path.name).is_file():shutil.copy2(backup/path.name,path)
        raise
    return segments,revision(segments_file)
