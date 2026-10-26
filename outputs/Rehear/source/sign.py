"""Development signing; set CALLS_SIGN_IDENTITY for a configured identity."""
import os,subprocess
from pathlib import Path
def sign(path):
    identity=os.environ.get('CALLS_SIGN_IDENTITY','-')
    runtime=Path(path)/'Contents/Resources/python'
    if runtime.exists():
        for f in runtime.rglob('*'):
            if not f.is_file() or f.is_symlink():continue
            with f.open('rb') as stream:magic=stream.read(4)
            if magic in (b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca'):
                subprocess.run(['codesign','--force','--sign',identity,'--timestamp=none',str(f)],check=True,capture_output=True)
    subprocess.run(['codesign','--force','--deep','--sign',identity,'--timestamp=none',str(path)],check=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(path)],check=True)
