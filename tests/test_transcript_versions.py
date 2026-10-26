import sys,tempfile,json
from pathlib import Path
sys.path.insert(0,str(Path('outputs/Rehear/source').resolve()))
from transcript import write_result
from transcript_versions import promote,migrate
with tempfile.TemporaryDirectory() as td:
 root=Path(td)/'Созвон';root.mkdir();version=root/'Улучшение';version.mkdir()
 old=[dict(start=0,end=2,text='Старый текст.')];new=[dict(start=0,end=2,text='Исправленный текст.')]
 write_result(root,root.name,old,'.playback.m4a');write_result(version,'Улучшено',new,'.playback.m4a')
 (root/'Запись.m4a').write_bytes(b'original');(root/'.chat.json').write_text('chat');(root/'Краткое содержание.txt').write_text('old summary')
 parent=dict(id='parent',output=str(root),status='done');child=dict(id='new',output=str(version),kind='improve',parentId='parent',status='done',modified=1)
 assert migrate([parent,child]);assert json.loads((root/'.segments.json').read_text())==new
 assert (root/'Запись.m4a').read_bytes()==b'original' and (root/'.chat.json').read_text()=='chat'
 assert not (root/'Краткое содержание.txt').exists();archive=next((root/'.transcript-versions').iterdir());assert (archive/'Краткое содержание.txt').read_text()=='old summary'
 assert json.loads((archive/'.segments.json').read_text())==old
 assert not migrate([parent,child]);assert len(list(root.glob('*.html')))==1
 bad=root/'bad';bad.mkdir();(bad/'.segments.json').write_text(json.dumps([dict(start=i,end=i+1,text='Повтор фразы.') for i in range(20)]))
 try:promote(parent,dict(id='bad',output=str(bad)));raise AssertionError()
 except ValueError:pass
 assert json.loads((root/'.segments.json').read_text())==new
 print('PASS verified version replaces main transcript; old text/summary archived; recordings/chat intact; idempotent migration; bad version rejected')
