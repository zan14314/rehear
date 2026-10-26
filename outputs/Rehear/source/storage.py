"""Commit finished transcripts with the original recording; roll back failed commits."""
import hashlib,json,shutil
from pathlib import Path

def signature_at(file,logical_path=None):
    file=Path(file);s=file.stat();location=Path(logical_path or file).resolve()
    return hashlib.sha256(f'{location}\0{s.st_size}\0{s.st_mtime_ns}'.encode()).hexdigest()

def write_json(path,value):
    path=Path(path);tmp=path.with_suffix(path.suffix+'.tmp');tmp.write_text(json.dumps(value,ensure_ascii=False,indent=2));tmp.replace(path)

def commit_result(staging,destination,source,job,persist,journal):
    staging,destination,source,journal=map(Path,(staging,destination,source,journal))
    recording=staging/('Запись'+source.suffix);final=destination/recording.name;old=dict(job)
    if destination.exists():raise FileExistsError('Папка результата уже существует')
    if recording.exists() or recording.is_symlink():raise FileExistsError('Место для записи занято')
    write_json(journal,{'source':str(source),'staging':str(staging),'destination':str(destination),'recording':recording.name,'job':old})
    moved=False;published=False
    try:
        source.rename(recording);moved=True
        meta=json.loads((staging/'.calls-result.json').read_text());meta.update(id=signature_at(recording,final),source=str(final),originalSource=str(source),formatVersion=3)
        write_json(staging/'.calls-result.json',meta)
        if destination.exists():raise FileExistsError('Папка результата уже существует')
        staging.rename(destination);published=True
        job.update(id=meta['id'],path=str(final),status='done',output=str(destination),progress=100)
        persist();journal.unlink(missing_ok=True)
    except BaseException:
        job.clear();job.update(old)
        try:
            if published:destination.rename(staging)
            if moved:
                if source.exists():raise RuntimeError('Исходный путь занят. Запись сохранена в '+str(recording))
                recording.rename(source)
            journal.unlink(missing_ok=True)
        except BaseException as recovery:
            raise RuntimeError('Не удалось откатить перенос; запись сохранена. '+str(recovery))
        raise

def recover_pending(journal,jobs,persist):
    journal=Path(journal)
    if not journal.exists():return
    entry=json.loads(journal.read_text());source=Path(entry['source']);staging=Path(entry['staging']);destination=Path(entry['destination']);name=entry['recording']
    old=entry['job'];job=next((j for j in jobs if j['id']==old['id'] or j.get('path')==str(destination/name)),None)
    if entry.get('migration'):
        recording=destination/name;marker=destination/'.calls-result.json'
        if job is None:job=dict(old);jobs.append(job)
        if not source.exists() and recording.is_file() and not recording.is_symlink():
            meta=dict(entry['metadata']);meta.update(id=signature_at(recording),source=str(recording),originalSource=str(source),formatVersion=3);write_json(marker,meta)
            job.update(id=meta['id'],path=str(recording),output=str(destination),status='done',progress=100)
        elif source.exists() and (not recording.exists() or recording.is_symlink()):
            if not recording.is_symlink():recording.symlink_to(source)
            write_json(marker,entry['metadata']);job.clear();job.update(old)
        else:raise RuntimeError('Незавершённый перенос сохранён: '+str(journal))
        persist();journal.unlink();return
    if destination.exists() and (destination/name).is_file() and not source.exists():
        meta=json.loads((destination/'.calls-result.json').read_text())
        if job is None:job=dict(old);jobs.append(job)
        job.update(id=meta['id'],path=str(destination/name),output=str(destination),status='done',progress=100,message='Готово')
        persist();journal.unlink();return
    if (staging/name).is_file() and not source.exists():(staging/name).rename(source)
    if source.exists() and not (staging/name).exists():
        shutil.rmtree(staging,ignore_errors=True)
        if job is not None:job.clear();job.update(old)
        persist();journal.unlink()
    else:raise RuntimeError('Незавершённый перенос сохранён для восстановления: '+str(journal))

def archive_existing(folder,source,job,persist,journal):
    folder,source,journal=map(Path,(folder,source,journal));recording=folder/('Запись'+source.suffix)
    marker=folder/'.calls-result.json';oldmeta=json.loads(marker.read_text());old=dict(job)
    if not source.is_file() or not recording.is_symlink() or recording.resolve()!=source.resolve():raise RuntimeError('Пара исходник/ссылка не подтверждена')
    write_json(journal,{'migration':True,'source':str(source),'staging':str(folder),'destination':str(folder),'recording':recording.name,'job':old,'metadata':oldmeta})
    moved=False
    try:
        recording.unlink();source.rename(recording);moved=True
        meta=dict(oldmeta);meta.update(id=signature_at(recording),source=str(recording),originalSource=str(source),formatVersion=3);write_json(marker,meta)
        job.update(id=meta['id'],path=str(recording),output=str(folder),status='done',progress=100)
        persist();journal.unlink(missing_ok=True)
    except BaseException:
        job.clear();job.update(old)
        if moved:
            if source.exists():raise RuntimeError('Исходный путь занят; запись сохранена в '+str(recording))
            recording.rename(source)
        if source.exists() and not recording.exists() and not recording.is_symlink():recording.symlink_to(source)
        write_json(marker,oldmeta);journal.unlink(missing_ok=True)
        raise
