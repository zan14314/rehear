"""Persistent macOS bookmarks; paths are a cache, never the identity."""
import json, os, subprocess, time
from storage import signature_at
from pathlib import Path

def identity(path):
    try:
        s=Path(path).stat()
        return [s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns]
    except OSError:return None

class Locations:
    def __init__(self, helper):self.helper=Path(helper);self.last=0;self.recovery_last=0
    def reconcile(self,state,force=False):
        if not self.helper.is_file():return False
        now=time.monotonic()
        if not force and now-self.last<2:return False
        self.last=now
        requests=[];targets=[];changed=False
        if now-self.recovery_last>30:
            self.recovery_last=now
            changed=self.recover_legacy(state)
        root={'path':state['folder'],'locations':state.get('folderLocation',{})}
        for job in [root]+state['jobs']:
            for field in ('path','output','parentOutput'):
                value=job.get(field)
                if not value:continue
                slot=job.setdefault('locations',{}).get(field,{})
                current=identity(value)
                # A bookmark must be resolved even if an unrelated file now occupies the old path.
                if slot.get('bookmark'):request={'bookmark':slot['bookmark']}
                elif current:request={'path':value}
                else:continue
                requests.append(request);targets.append((job,field,slot))
        if not requests:return False
        try:
            p=subprocess.run([str(self.helper)],input=json.dumps(requests),capture_output=True,text=True,timeout=20,check=True)
            resolved=json.loads(p.stdout)
        except (OSError,ValueError,subprocess.SubprocessError):return False
        for (job,field,old),result in zip(targets,resolved):
            if not result:continue
            ident=identity(result['path'])
            if old.get('identity') and field=='path' and ident and ident[:2]!=old['identity'][:2]:continue
            slot=dict(result,identity=old.get('identity') or ident)
            if old!=slot:job['locations'][field]=slot;changed=True
            if job[field]!=result['path']:
                job[field]=result['path'];changed=True
                if field=='path':job['name']=Path(job[field]).name
        state['folder']=root['path'];state['folderLocation']=root['locations']
        return changed

    def recover_legacy(self,state):
        changed=False
        missing=[j for j in state['jobs'] if j.get('output') and not Path(j['output']).is_dir() and not j.get('locations',{}).get('output')]
        markers=[]
        if missing and Path(state['folder']).is_dir():
            for base,dirs,files in os.walk(state['folder']):
                dirs[:]=[d for d in dirs if not d.startswith('.')]
                if '.calls-result.json' in files:markers.append(Path(base)/'.calls-result.json')
        for j in missing:
            # Indexed lookup also covers folders moved outside the watched directory.
            name=Path(j['output']).name.replace('\\','\\\\').replace('"','\\"')
            try:
                hits=subprocess.run(['/usr/bin/mdfind','-onlyin',str(Path.home()),'kMDItemFSName == "'+name+'"'],capture_output=True,text=True,timeout=3).stdout.splitlines()
            except (OSError,subprocess.SubprocessError):hits=[]
            candidates=set(markers+[Path(p)/'.calls-result.json' for p in hits if '/.Trash/' not in p])
            matches=[]
            for marker in candidates:
                try:
                    if json.loads(marker.read_text()).get('id')==j['id']:matches.append(marker.parent)
                except (OSError,ValueError):pass
            if len(matches)==1:
                old=Path(j['output']);new=matches[0];j['output']=str(new);changed=True
                try:relative=Path(j['path']).relative_to(old);j['path']=str(new/relative)
                except ValueError:pass
        for j in state['jobs']:
            if Path(j['path']).is_file() or j.get('locations',{}).get('path'):continue
            folder=Path(j.get('output') or '/nonexistent')
            candidates=[p for p in folder.iterdir() if p.is_file() and not p.name.startswith('.')] if folder.is_dir() else []
            matches=[]
            for candidate in candidates:
                try:
                    if signature_at(candidate,j['path'])==j['id']:matches.append(candidate)
                except OSError:pass
            if len(matches)==1:j['path']=str(matches[0]);j['name']=matches[0].name;changed=True
        return changed
