"""Readable timestamped transcripts and a completely offline viewer."""
import html,json,re
from plain_text import write_plain
from pathlib import Path
from urllib.parse import quote

def seconds(value):
    h,m,s= value.replace(',', '.').split(':');return int(h)*3600+int(m)*60+float(s)

def stamp(value):
    value=max(0,int(value));return f'{value//3600:02d}:{value//60%60:02d}:{value%60:02d}'

def parse_srt(value):
    result=[]
    for block in re.split(r'\n\s*\n',value.replace('\r','').strip()):
        lines=block.splitlines()
        index=next((i for i,l in enumerate(lines) if '-->' in l),None)
        if index is None:continue
        a,b=lines[index].split('-->',1)
        try:start,end=seconds(a.strip()),seconds(b.strip().split()[0])
        except (ValueError,IndexError):continue
        text=' '.join(l.strip() for l in lines[index+1:]).strip()
        if text:result.append({'start':start,'end':end,'text':text})
    return result

def readable(title,segments):
    return title+'\n\n'+ '\n\n'.join(f'[{stamp(s["start"])} → {stamp(s["end"])}]\n{s["text"]}' for s in segments)+'\n'

def render(title,segments,audio,txt_name):
    rows='\n'.join(f'<button class="segment" data-start="{s["start"]}" data-end="{s["end"]}"><span class="time">{stamp(s["start"])}</span><span class="words">{html.escape(s["text"])}</span></button>' for s in segments)
    values={'TITLE':html.escape(title),'ROWS':rows,'AUDIO':html.escape(quote(audio)),'TXT':html.escape(quote(txt_name)),'COUNT':str(len(segments))}
    return re.sub(r'@@(TITLE|ROWS|AUDIO|TXT|COUNT)@@',lambda m:values[m.group(1)],TEMPLATE)

def write_result(folder,base,segments,audio):
    folder=Path(folder)
    if not segments:raise ValueError('Не найдены сегменты с таймкодами')
    txt=folder/(base+'.txt');view=folder/(base+'.html')
    for path,value in [(txt,readable(base,segments)),(view,render(base,segments,audio,txt.name))]:
        temp=path.with_suffix(path.suffix+'.tmp');temp.write_text(value,encoding='utf-8-sig' if path.suffix=='.txt' else 'utf-8');temp.replace(path)
    (folder/'.segments.json').write_text(json.dumps(segments,ensure_ascii=False),encoding='utf-8')
    write_plain(folder,segments)
    return view

TEMPLATE=r'''<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; media-src file: data:; img-src data:"><title>@@TITLE@@</title><style>
:root{color-scheme:light dark;--bg:#f7f8fc;--paper:white;--ink:#202839;--muted:#6c7588;--accent:#3869e8;--line:#e4e8f1;--active:#edf2ff}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:17px/1.65 -apple-system,BlinkMacSystemFont,sans-serif}main{max-width:960px;margin:auto;padding:32px 28px 100px}h1{font-size:29px;line-height:1.3;margin:8px 0 14px}.eyebrow{font-size:12px;letter-spacing:2px;color:var(--accent);font-weight:700}a{color:var(--accent)}.controls{position:sticky;top:0;background:var(--bg);padding:16px 0;z-index:2;border-bottom:1px solid var(--line)}audio{width:100%;height:44px}.toolbar{display:flex;gap:12px;align-items:center;margin-top:12px;flex-wrap:wrap}input[type=search]{flex:1;min-width:180px;border:1px solid var(--line);background:var(--paper);color:var(--ink);font:inherit;border-radius:10px;padding:9px 12px}button,select{font:inherit;color:var(--ink);background:var(--paper);border:1px solid var(--line);border-radius:8px;padding:5px 10px;cursor:pointer}.hint{font-size:13px;color:var(--muted);margin:12px 0 20px}.segment{width:100%;display:grid;grid-template-columns:88px 1fr;text-align:left;gap:14px;border:0;border-radius:10px;padding:14px;margin:4px 0;background:var(--paper);line-height:1.65}.segment:hover{background:var(--active)}.segment.active{background:var(--active);box-shadow:inset 3px 0 var(--accent)}.time{font-size:13px;color:var(--accent);font-variant-numeric:tabular-nums;padding-top:3px}.words{white-space:pre-wrap}mark{background:#ffdf8a;color:#242424;border-radius:3px}#status{color:var(--muted);font-size:13px}.segment[hidden]{display:none}#mediaHelp{color:#b35c23;font-size:14px;display:none}@media(prefers-color-scheme:dark){:root{--bg:#11151d;--paper:#1b2130;--ink:#e8edf6;--muted:#9da8bb;--accent:#91b1ff;--line:#30394b;--active:#26354f}}@media(max-width:600px){main{padding:20px 12px 60px}.segment{grid-template-columns:70px 1fr;gap:6px;padding:10px}h1{font-size:23px}}
</style></head><body><main><div class="eyebrow">REHEAR · ТРАНСКРИПТ</div><h1>@@TITLE@@</h1><div class="controls"><audio id="audio" controls preload="metadata" src="@@AUDIO@@"></audio><div id="mediaHelp">Браузер не смог воспроизвести исходник. Открой этот транскрипт в приложении «Rehear» или слушай запись отдельно — текст и поиск доступны.</div><div class="toolbar"><input type="search" id="search" placeholder="Найти слово или фразу" aria-label="Поиск по транскрипту"><select id="speed" aria-label="Скорость воспроизведения"><option value="0.75">0,75×</option><option value="1" selected>1×</option><option value="1.25">1,25×</option><option value="1.5">1,5×</option><option value="2">2×</option></select><button id="back" title="Назад на 10 секунд">−10 с</button><button id="copy">Копировать текст</button><a href="@@TXT@@" download>TXT с таймкодами</a></div><div class="toolbar"><label><input type="checkbox" id="follow"> Следовать за записью</label><span id="status">@@COUNT@@ фрагментов</span></div></div><p class="hint">Нажми на фрагмент, чтобы слушать с этого места. Таймкоды приблизительные. Для неточно распознанных имён и терминов сверяйся с записью.</p><section id="segments">@@ROWS@@</section></main><script>
const audio=document.getElementById('audio'),rows=[...document.querySelectorAll('.segment')],search=document.getElementById('search'),status=document.getElementById('status');const original=rows.map(r=>r.querySelector('.words').textContent);let active=null;
function timestamp(n){n=Math.max(0,Math.floor(n));return [Math.floor(n/3600),Math.floor(n/60)%60,n%60].map(v=>String(v).padStart(2,'0')).join(':')}
rows.forEach(row=>row.addEventListener('click',()=>{audio.currentTime=Number(row.dataset.start);audio.play().catch(()=>{document.getElementById('mediaHelp').style.display='block'})}));
audio.addEventListener('error',()=>document.getElementById('mediaHelp').style.display='block');audio.addEventListener('timeupdate',()=>{let found=rows.find(r=>audio.currentTime>=Number(r.dataset.start)&&audio.currentTime<Number(r.dataset.end));if(active!==found){if(active)active.classList.remove('active');active=found;if(active){active.classList.add('active');if(document.getElementById('follow').checked&&!search.value)active.scrollIntoView({behavior:'smooth',block:'center'})}}});
document.getElementById('speed').addEventListener('change',e=>audio.playbackRate=Number(e.target.value));document.getElementById('back').addEventListener('click',()=>audio.currentTime=Math.max(0,audio.currentTime-10));
search.addEventListener('input',()=>{const query=search.value.trim().toLocaleLowerCase();let count=0;rows.forEach((row,i)=>{const words=row.querySelector('.words'),text=original[i],lower=text.toLocaleLowerCase();row.hidden=!!query&&!lower.includes(query);words.textContent='';if(!row.hidden)count++;if(!query){words.textContent=text;return}let pos=0,next;while((next=lower.indexOf(query,pos))!==-1){words.append(document.createTextNode(text.slice(pos,next)));let mark=document.createElement('mark');mark.textContent=text.slice(next,next+query.length);words.append(mark);pos=next+query.length}words.append(document.createTextNode(text.slice(pos)))});status.textContent=query?'Найдено фрагментов: '+count:rows.length+' фрагментов'});
document.getElementById('copy').addEventListener('click',()=>{const text=rows.filter(r=>!r.hidden).map(r=>'['+timestamp(Number(r.dataset.start))+' → '+timestamp(Number(r.dataset.end))+']\n'+r.querySelector('.words').textContent).join('\n\n');const field=document.createElement('textarea');field.value=text;document.body.append(field);field.select();const ok=document.execCommand('copy');field.remove();status.textContent=ok?'Текст скопирован':'Используй TXT для копирования'});
</script></body></html>'''
