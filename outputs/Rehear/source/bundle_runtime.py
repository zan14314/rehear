"""Assemble a relocatable local runtime. Used by both build entrypoints."""
from pathlib import Path
import os,shutil,subprocess

def bundle_runtime(app):
    app=Path(app);res=app/'Contents/Resources';runtime=res/'python';origin=Path('/Library/Frameworks/Python.framework/Versions/3.12')
    if not runtime.exists():
        (runtime/'bin').mkdir(parents=True);(runtime/'lib').mkdir()
        shutil.copy2(origin/'Resources/Python.app/Contents/MacOS/Python',runtime/'bin/python3')
        shutil.copy2(origin/'Python',runtime/'Python')
        shutil.copytree(origin/'lib/python3.12',runtime/'lib/python3.12',ignore=shutil.ignore_patterns('site-packages','__pycache__','test','tests','idlelib','tkinter','config-3.12-darwin'))
        for f in (origin/'lib').glob('*.dylib'):
            if f.name=='libpython3.12.dylib':continue
            shutil.copy2(f,runtime/'lib'/f.name)
        # Every dependency points inside the bundle or to a macOS system library.
        for f in runtime.rglob('*'):
            if not f.is_file():continue
            if f.name not in ('python3','Python') and f.suffix not in ('.so','.dylib'):continue
            deps=subprocess.check_output(['otool','-L',str(f)],text=True)
            changes=[]
            if f.name=='Python' or f.suffix=='.dylib':changes += ['-id','@loader_path/'+f.name]
            for line in deps.splitlines():
                dep=line.strip().split(' (')[0]
                if dep.startswith(str(origin)):
                    rel=Path(dep).relative_to(origin)
                    target=runtime/rel
                    if str(rel)=='Python':target=runtime/'Python'
                    if not target.exists():raise RuntimeError('Missing bundled dependency: '+dep)
                    replacement='@loader_path/'+os.path.relpath(target,f.parent)
                    changes += ['-change',dep,replacement]
            subprocess.run(['codesign','--remove-signature',str(f)],capture_output=True)
            if changes:subprocess.run(['install_name_tool']+changes+[str(f)],check=True)
    for f in runtime.rglob('*'):
        if f.is_file() and not f.is_symlink():f.chmod(f.stat().st_mode | 0o200)
    # Unused GUI/terminal Python extensions are not part of the application runtime.
    for pattern in ('_tkinter*','_curses*'):
        for f in (runtime/'lib/python3.12/lib-dynload').glob(pattern):f.unlink()
    for pattern in ('libtcl*','libtk*','libncurses*','libmenu*','libpanel*','libform*'):
        for f in (runtime/'lib').glob(pattern):f.unlink()
    own_ffmpeg=Path(__file__).resolve().parents[3]/'work/distribution-sources/prefix/bin/ffmpeg'
    if own_ffmpeg.exists():shutil.copy2(own_ffmpeg,res/'ffmpeg')
    whisper=Path(__file__).resolve().parents[3]/'work/whisper-macos15/bin/whisper-cli'
    if whisper.exists():shutil.copy2(whisper,res/'whisper-cli')
    for name in ('llama-helper',):
        target=res/name
        if not target.exists():shutil.copy2(Path('/Applications/meetily.app/Contents/MacOS')/name,target)
    # Model weights are downloaded into Application Support, never distributed in the app.
    if (res/'models').exists():shutil.rmtree(res/'models')
    notices=res/'ThirdParty';notices.mkdir(exist_ok=True)
    project=Path(__file__).resolve().parents[3]
    licenses=Path(__file__).resolve().parent/'third-party-licenses'
    if licenses.exists():shutil.copytree(licenses,notices/'Licenses',dirs_exist_ok=True)
    license=project/'work/meetily-source/LICENSE.md'
    if license.exists():shutil.copy2(license,notices/'Meetily-LICENSE.md')
    (notices/'RUNTIME.txt').write_text('Python 3.12: https://docs.python.org/3.12/license.html\nFFmpeg 8.0 + x264 + libvpx + Opus (GPL build; exact source archives supplied with distribution): https://ffmpeg.org/legal.html\nllama-helper: Meetily; source https://github.com/meetily/meetily\nWhisper: see whisper-LICENSE\nModel weights are not distributed. Download catalog includes pinned origins and checksums; license links are shown before download.\n')
