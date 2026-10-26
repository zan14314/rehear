#!/usr/bin/env python3
"""Rebuild app sources using the released runtime as a local template."""
import argparse,pathlib,subprocess,tempfile,shutil,sys
p=argparse.ArgumentParser();p.add_argument('--template',type=pathlib.Path,required=True);args=p.parse_args()
root=pathlib.Path(__file__).resolve().parents[1];target=root/'outputs/Созвоны/Rehear.app'
if not args.template.is_file():p.error('Template ZIP not found')
if target.exists():p.error('Template app already exists; move it aside before rebuilding')
with tempfile.TemporaryDirectory() as td:
 subprocess.run(['ditto','-x','-k',str(args.template.resolve()),td],check=True)
 apps=list(pathlib.Path(td).rglob('Rehear.app'))
 if len(apps)!=1:raise RuntimeError('Expected one Rehear.app in release ZIP')
 shutil.copytree(apps[0],target)
(root/'work').mkdir(exist_ok=True)
subprocess.run([sys.executable,str(root/'outputs/Созвоны/source/build.py')],cwd=root,check=True)
