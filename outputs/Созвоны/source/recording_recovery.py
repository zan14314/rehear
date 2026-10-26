"""Discover journalled/legacy CAF recordings and rebuild without deleting sources."""
import hashlib,json,time,os
from pathlib import Path
from reliability import atomic_json,space

def sessions(roots):
    rows=[];seen=set()
    for root in roots:
        root=Path(root)
        if not root.is_dir():continue
        # Only inspect recording directories, never recursively crawl all user files.
        for folder in [root,root/'Записи']:
            if not folder.is_dir():continue
            for caf in folder.glob('*.caf'):
                if caf.name.endswith('.system.caf'):base=str(caf)[:-11]
                elif caf.name.endswith('.mic.caf'):base=str(caf)[:-8]
                else:continue
                if base in seen:continue
                seen.add(base);marker=Path(base+'.session.json')
                try:meta=json.loads(marker.read_text()) if marker.exists() else {}
                except (OSError,ValueError):meta={}
                if meta.get('resolved'):continue
                paths=[Path(base+'.system.caf'),Path(base+'.mic.caf')];size=sum(p.stat().st_size for p in paths if p.is_file())
                if not size:continue
                rows.append(dict(id=hashlib.sha256(base.encode()).hexdigest(),base=base,name=Path(base).name,size=size,modified=max(p.stat().st_mtime for p in paths if p.exists()),offset=float(meta.get('offset',0))))
    return sorted(rows,key=lambda r:r['modified'],reverse=True)

def rebuild(row,run):
    base=row['base'];tracks=[(kind,Path(base+suffix)) for kind,suffix in [('system','.system.caf'),('mic','.mic.caf')] if Path(base+suffix).is_file()]
    if not tracks:raise ValueError('Дорожки записи не найдены')
    folder=Path(base).parent;space(folder,max(128*1024**2,int(row['size']*.3)))
    final=folder/(Path(base).name+' — восстановлено.m4a');n=2
    while final.exists():final=folder/(Path(base).name+f' — восстановлено ({n}).m4a');n+=1
    tmp=folder/('.recover-'+row['id']+'.m4a');args=['-nostdin','-y']
    for _,path in tracks:args+=['-i',path]
    if len(tracks)==2:
        offset=row.get('offset',0);a=max(0,int(-offset*1000));b=max(0,int(offset*1000))
        args+=['-filter_complex',f'[0:a]adelay={a}:all=1[a];[1:a]adelay={b}:all=1[b];[a][b]amix=inputs=2:duration=longest:normalize=0,alimiter=limit=0.95[out]','-map','[out]']
    args+=['-c:a','aac','-b:a','160k',tmp]
    try:
        run(args)
        if not tmp.is_file() or not tmp.stat().st_size:raise ValueError('Не удалось восстановить звук')
        os.replace(tmp,final)
        atomic_json(base+'.session.json',dict(resolved=True,recovered=str(final),time=time.time()))
    finally:tmp.unlink(missing_ok=True)
    return final
