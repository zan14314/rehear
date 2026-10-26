"""Journalled publication of transcript versions; restart finishes or rolls back."""
import json,shutil,time,uuid,os
from pathlib import Path
from transcript import write_result
from transcription_guard import check
from reliability import atomic_json
NAMES={'.segments.json','.subtitles.srt','.plain-meta.json','.transcription-warning.json','.active-transcript.json','Сплошной текст.txt','Краткое содержание.txt','.text-history.json'}
def managed(root):return [p for p in root.iterdir() if p.is_file() and (p.name in NAMES or p.suffix in ('.html','.txt'))]
def recover(root):
    root=Path(root);journal=root/'.transcript-transaction.json'
    if not journal.exists():return
    entry=json.loads(journal.read_text())
    if not isinstance(entry,dict) or not all(isinstance(entry.get(k),str) for k in ('stage','archive','id')) or not all(isinstance(entry.get(k),list) and all(isinstance(n,str) and Path(n).name==n and n not in ('.','..') for n in entry[k]) for k in ('old','new')):raise ValueError('Повреждён журнал версии; архивы сохранены')
    stage=root/entry['stage'];archive=root/'.transcript-versions'/entry['archive']
    if Path(entry['stage']).name!=entry['stage'] or not stage.name.startswith('.publish-') or Path(entry['archive']).name!=entry['archive'] or entry['archive'] in ('.','..'):raise ValueError('Некорректная история версии')
    try:
        for name in entry['old']:
            if Path(name).name!=name:raise ValueError('Некорректный путь версии')
            (root/name).unlink(missing_ok=True)
        for name in entry['new']:
            if Path(name).name!=name:raise ValueError('Некорректный путь версии')
            source=stage/name
            if source.exists():
                tmp=root/('.version-'+uuid.uuid4().hex);shutil.copy2(source,tmp);os.replace(tmp,root/name)
            else:raise ValueError('Неполная новая версия')
        atomic_json(root/'.active-transcript.json',dict(id=entry['id'],archive=str(archive)))
    except BaseException:
        for name in entry['new']:(root/name).unlink(missing_ok=True)
        for name in entry['old']:
            if (archive/name).exists():shutil.copy2(archive/name,root/name)
        raise
    journal.unlink();shutil.rmtree(stage,ignore_errors=True)

def promote(parent,version):
    root=Path(parent['output']);source=Path(version['output']);recover(root)
    marker=root/'.active-transcript.json'
    if marker.exists() and json.loads(marker.read_text()).get('id')==version['id']:
        parent['activeTranscript']=version['id'];return
    segments=json.loads((source/'.segments.json').read_text());check(segments)
    key=uuid.uuid4().hex;archive=root/'.transcript-versions'/key;archive.mkdir(parents=True)
    files=managed(root)
    for p in files:
        shutil.copy2(p,archive/p.name)
        with (archive/p.name).open('rb') as stream:os.fsync(stream.fileno())
    atomic_json(archive/'version.json',dict(id=key,created=time.time(),label='Предыдущая расшифровка'))
    stage=root/('.publish-'+key);stage.mkdir()
    try:
        write_result(stage,root.name,segments,'.playback.m4a')
        atomic_json(stage/'.text-history.json',dict(undo=[],redo=[]))
        for name in ['.subtitles.srt','Сплошной текст.txt','.plain-meta.json']:
            if (source/name).exists():shutil.copy2(source/name,stage/name)
        for file in stage.iterdir():
            if file.is_file():
                with file.open('rb') as stream:os.fsync(stream.fileno())
        atomic_json(root/'.transcript-transaction.json',dict(id=version['id'],stage=stage.name,archive=key,old=[p.name for p in files],new=[p.name for p in stage.iterdir()]))
        recover(root)
    except BaseException:
        # Keep journal+staging if recovery needs another restart (e.g. disk full).
        if not (root/'.transcript-transaction.json').exists():shutil.rmtree(stage,ignore_errors=True)
        raise
    parent.update(message='Расшифровка обновлена',activeTranscript=version['id'])
    version['applied']=True

def history(root):
    root=Path(root);rows=[]
    for folder in (root/'.transcript-versions').glob('*'):
        path=folder/'.segments.json'
        if not path.is_file():continue
        try:
            seg=json.loads(path.read_text());created=folder.stat().st_mtime
            meta=folder/'version.json'
            if meta.exists():created=json.loads(meta.read_text()).get('created',created)
            rows.append(dict(id=folder.name,created=created,label=time.strftime('%d.%m.%Y %H:%M',time.localtime(created)),preview=' '.join(s['text'] for s in seg)[:500]))
        except (OSError,ValueError,KeyError):continue
    return sorted(rows,key=lambda row:row['created'],reverse=True)

def restore(parent,key):
    if not key or Path(key).name!=key or key not in {r['id'] for r in history(parent['output'])}:raise ValueError('Версия не найдена')
    promote(parent,dict(id='restored-'+uuid.uuid4().hex,output=str(Path(parent['output'])/'.transcript-versions'/key)))

def migrate(jobs):
    changed=False
    for parent in jobs:
        if parent.get('kind') or parent.get('status')!='done' or not parent.get('output'):continue
        root=Path(parent['output'])
        if not root.is_dir():continue
        try:
            recover(root)
            marker=root/'.active-transcript.json'
            if marker.exists():
                active=json.loads(marker.read_text())['id']
                if parent.get('activeTranscript')!=active:parent['activeTranscript']=active;changed=True
                continue
            versions=[j for j in jobs if j.get('kind')=='improve' and j.get('parentId')==parent['id'] and j.get('status')=='done' and j.get('output') and Path(j['output']).is_dir()]
            if versions:promote(parent,max(versions,key=lambda j:j.get('modified',0)));changed=True
        except (OSError,ValueError,KeyError):
            parent['message']='Не удалось восстановить версию. Копии сохранены; повтори восстановление после освобождения места.'
    return changed
