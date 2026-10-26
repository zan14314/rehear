"""Curated, pinned model downloads. Never publish partial or unchecked weights."""
import hashlib,json,shutil,subprocess,threading,time
from pathlib import Path

class Downloads:
    def __init__(self,catalog,root,complete):
        self.catalog=json.loads(Path(catalog).read_text());self.root=Path(root);self.complete=complete
        self.lock=threading.RLock();self.status={};self.proc=None;self.cancel=threading.Event();self.busy=False
        self.root.mkdir(parents=True,exist_ok=True)
    def rows(self):
        with self.lock:
            rows=[]
            for item in self.catalog:
                row=dict(item);path=self.root/item['file'];partial=path.with_suffix(path.suffix+'.partial')
                row.update(installed=path.is_file() and path.stat().st_size==item['size'],downloaded=partial.stat().st_size if partial.exists() else 0,status='',error='')
                row.update(self.status.get(item['id'],{}));rows.append(row)
            return rows
    def start(self,key):
        with self.lock:
            if self.busy:raise ValueError('Дождись загрузки или отмени её')
            item=next((r for r in self.catalog if r['id']==key),None)
            if not item:raise ValueError('Неизвестная модель')
            self.busy=True;self.cancel.clear();self.status[key]={'status':'downloading','error':''}
            threading.Thread(target=self._download,args=(item,),daemon=True).start()
    def stop(self):
        with self.lock:
            self.cancel.set()
            if self.proc and self.proc.poll() is None:self.proc.terminate()
    def _download(self,item):
        key=item['id'];dest=self.root/item['file'];partial=dest.with_suffix(dest.suffix+'.partial');log=self.root/(item['file']+'.download.log')
        try:
            have=partial.stat().st_size if partial.exists() else 0
            if shutil.disk_usage(self.root).free<max(0,item['size']-have)+512*1024**2:raise ValueError('Недостаточно места: нужен размер модели и ещё 512 МБ')
            if have>item['size']:partial.unlink();have=0
            with log.open('w') as output:
                args=['/usr/bin/curl','--fail','--location','--silent','--show-error','--proto','=https','--proto-redir','=https','--connect-timeout','20','--speed-limit','1024','--speed-time','60','--retry','2','--continue-at','-','--output',str(partial),item['url']]
                if have==item['size']:result=0
                else:
                    with self.lock:
                        if self.cancel.is_set():raise InterruptedError()
                        self.proc=subprocess.Popen(args,stdout=subprocess.DEVNULL,stderr=output)
                    result=self.proc.wait()
            if self.cancel.is_set():raise InterruptedError()
            if result:raise ValueError('Загрузка прервалась. Проверь интернет и нажми «Продолжить».')
            with self.lock:self.status[key]={'status':'verifying','error':''}
            if partial.stat().st_size!=item['size']:raise ValueError('Неполный файл модели. Повтори загрузку.')
            digest=hashlib.sha256()
            with partial.open('rb') as stream:
                while chunk:=stream.read(4*1024**2):
                    if self.cancel.is_set():raise InterruptedError()
                    digest.update(chunk)
            if digest.hexdigest()!=item['sha256']:
                partial.unlink();raise ValueError('Контрольная сумма не совпала. Повтори загрузку.')
            partial.replace(dest)
            self.complete(item,dest)
            with self.lock:self.status[key]={'status':'done','error':''}
        except InterruptedError:
            with self.lock:self.status[key]={'status':'paused','error':''}
        except Exception as error:
            with self.lock:self.status[key]={'status':'error','error':str(error)}
        finally:
            with self.lock:self.proc=None;self.busy=False
