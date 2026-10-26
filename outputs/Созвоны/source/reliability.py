"""Durable state and privacy-safe failure records. No transcript contents in diagnostics."""
import json,os,shutil,time,uuid
from pathlib import Path

def atomic_json(path,value):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    tmp=path.with_name('.'+path.name+'.'+uuid.uuid4().hex+'.tmp')
    try:
        with tmp.open('w') as f:
            json.dump(value,f,ensure_ascii=False,indent=2);f.flush();os.fsync(f.fileno())
        os.replace(tmp,path)
        try:
            fd=os.open(path.parent,os.O_RDONLY);os.fsync(fd);os.close(fd)
        except OSError:pass
    finally:tmp.unlink(missing_ok=True)

def valid_state(value):
    return isinstance(value,dict) and isinstance(value.get('folder'),str) and isinstance(value.get('jobs'),list) and all(isinstance(j,dict) and all(isinstance(j.get(k),str) for k in ('id','path','status')) for j in value['jobs']) and len({j['id'] for j in value['jobs']})==len(value['jobs'])
def load_state(path,default):
    path=Path(path)
    if not path.exists():return default(),''
    try:
        value=json.loads(path.read_text())
        if not valid_state(value):raise ValueError('schema')
        return value,''
    except (OSError,ValueError,TypeError):
        damaged=path.with_name('state.damaged-'+time.strftime('%Y%m%d-%H%M%S')+'-'+uuid.uuid4().hex[:6]+'.json')
        shutil.copy2(path,damaged)
        try:
            value=json.loads(path.with_suffix('.backup.json').read_text())
            if not valid_state(value):raise ValueError('schema')
            return value,'Состояние библиотеки восстановлено из резервной копии. Повреждённый файл сохранён отдельно.'
        except (OSError,ValueError,TypeError):
            return default(),'Не удалось прочитать библиотеку. Записи не удалены. Открой «Проверка и восстановление» в настройках.'
def save_state(path,value):
    path=Path(path)
    if not valid_state(value):raise ValueError('Некорректное состояние библиотеки')
    if path.exists():
        try:
            old=json.loads(path.read_text())
            if valid_state(old):atomic_json(path.with_suffix('.backup.json'),old)
        except (OSError,ValueError):pass
    atomic_json(path,value)

def failure(data,stage,code,model='',kind=''):
    # Do not copy subprocess errors: they may contain private paths and speech.
    value=dict(time=time.strftime('%Y-%m-%d %H:%M:%S'),stage=stage,code=code,model=Path(model).name,kind=kind)
    atomic_json(Path(data)/'last-failure.json',value)
    return value

def space(path,needed=512*1024**2):
    if shutil.disk_usage(path).free<needed:raise ValueError('Недостаточно свободного места для обработки. Освободи место и повтори; исходная запись сохранена.')
