"""Release gate: every bundled Mach-O ARM64 slice must load on macOS 15."""
import re,subprocess,json
from pathlib import Path
MINIMUM='15.0'
def check(app):
    rows=[]
    for path in Path(app).rglob('*'):
        if not path.is_file() or path.is_symlink():continue
        with path.open('rb') as stream:magic=stream.read(4)
        if magic not in (b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca'):continue
        arch=subprocess.check_output(['lipo','-archs',str(path)],text=True).split()
        if 'arm64' not in arch:raise RuntimeError('Нет ARM64: '+str(path))
        output=subprocess.check_output(['vtool','-arch','arm64','-show-build',str(path)],text=True)
        versions=re.findall(r'minos\s+([\d.]+)',output)
        if not versions:
            output=subprocess.check_output(['otool','-arch','arm64','-l',str(path)],text=True)
            match=re.search(r'LC_VERSION_MIN_MACOSX\s+cmdsize\s+\d+\s+version\s+([\d.]+)',output)
            versions=[match[1]] if match else []
        if not versions:raise RuntimeError('Не определена минимальная macOS: '+str(path))
        if any(tuple(map(int,v.split('.')[:2]))>(15,0) for v in versions):raise RuntimeError('Компонент требует macOS новее 15: '+str(path))
        dependencies=subprocess.check_output(['otool','-arch','arm64','-L',str(path)],text=True)
        for line in dependencies.splitlines()[1:]:
            dep=line.strip().split(' (')[0]
            if dep.startswith('/') and not dep.startswith(('/System/Library/','/usr/lib/')):raise RuntimeError('Внешняя зависимость: '+dep)
        rows.append(dict(path=str(path.relative_to(app)),minimum=versions[0]))
    if not rows:raise RuntimeError('Нет исполняемых компонентов')
    return rows
if __name__=='__main__':
    import sys
    rows=check(Path(sys.argv[1]));print(json.dumps(rows,ensure_ascii=False,indent=2))
