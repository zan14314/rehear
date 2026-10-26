"""Lossless plain transcripts. The model chooses breaks, never rewrites words."""
import hashlib,json,re
from pathlib import Path
NAME='Сплошной текст.txt'
def source_text(segments):return ' '.join(s['text'].strip() for s in segments if s['text'].strip())
def revision(segments):return hashlib.sha256(source_text(segments).encode()).hexdigest()
def write_plain(folder,segments,paragraphs=None,preview=False,method=None):
    folder=Path(folder);target=folder/NAME;meta=folder/'.plain-meta.json';digest=revision(segments)
    if paragraphs is None:
        try:
            if target.is_file() and json.loads(meta.read_text()).get('revision')==digest:return target
        except (OSError,ValueError):pass
    text=source_text(segments) if paragraphs is None else paragraphs
    if text.split()!=source_text(segments).split():raise ValueError('Разбиение изменило исходный текст')
    temp=folder/'.plain-tmp';temp.write_text(text+'\n',encoding='utf-8-sig');temp.replace(target)
    meta.write_text(json.dumps(dict(revision=digest,structured=paragraphs is not None and not preview,method=method or ("quick" if preview else "ai" if paragraphs is not None else "raw"))))
    return target

def structured(folder,segments):
    try:
        meta=json.loads((Path(folder)/'.plain-meta.json').read_text());return meta.get('revision')==revision(segments) and meta.get('structured',False)
    except (OSError,ValueError):return False

def quick_paragraphs(segments):
    paragraphs=[];group=[];length=0;previous_end=None
    for segment in segments:
        text=segment['text'].strip()
        if not text:continue
        pause=previous_end is not None and segment.get('start',previous_end)-previous_end>=1.2
        if group and ((pause and length>=180) or length+len(text)>750):
            paragraphs.append(' '.join(group));group=[];length=0
        # Sentence boundaries also bound paragraphs when subtitle blocks are huge.
        for sentence in re.split(r'(?<=[.!?…])\s+',text):
            if group and length+len(sentence)>750:
                paragraphs.append(' '.join(group));group=[];length=0
            group.append(sentence);length+=len(sentence)+1
        previous_end=segment.get('end',previous_end)
    if group:paragraphs.append(' '.join(group))
    return '\n\n'.join(paragraphs)

def paragraph_text(segments,generate,progress=None,fallback=None):
    sentences=re.split(r'(?<=[.!?…])\s+',source_text(segments));units=[]
    for sentence in sentences:
        if len(sentence)<=1500:units.append(sentence);continue
        words=sentence.split();piece=[];length=0
        for word in words:
            if len(word)>5000:raise ValueError('Слишком длинный фрагмент для разбиения; доступен исходный текст')
            if piece and length+len(word)>1200:units.append(' '.join(piece));piece=[];length=0
            piece.append(word);length+=len(word)+1
        if piece:units.append(' '.join(piece))
    def preview(unit):return unit if len(unit)<=180 else unit[:110]+" … "+unit[-60:]
    chunks=[];chunk=[];size=0
    for unit in units:
        if chunk and (size+len(preview(unit))>4500 or len(chunk)>=48):chunks.append(chunk);chunk=[];size=0
        chunk.append(unit);size+=len(preview(unit))
    if chunk:chunks.append(chunk)
    def format_chunk(chunk,depth=0):
        if len(chunk)==1:return chunk
        numbered='\n'.join(f'{i+1}: {preview(s)}' for i,s in enumerate(chunk))
        prompt=f'Всего фрагментов: {len(chunk)}. Допустимые номера: от 2 до {len(chunk)}. Длинные фрагменты показаны началом и концом через … . Ответ только JSON, без объяснений.\n'+numbered
        try:
            reply=generate(prompt)
            match=re.search(r'\{[^{}]*\}',reply)
            data=json.loads(match[0] if match else reply);breaks=data['breaks']
            if not isinstance(breaks,list) or any(type(i)!=int or i<1 or i>len(chunk) for i in breaks):raise ValueError('Некорректные границы абзацев')
        except (ValueError,KeyError,TypeError):
            # A bad response must not discard all earlier chunks. Retry on a
            # strictly smaller input; singleton leaves require no model call.
            if depth>=1:
                if fallback:fallback()
                groups=[];group=[];length=0
                for unit in chunk:
                    if group and length+len(unit)>650:groups.append(' '.join(group));group=[];length=0
                    group.append(unit);length+=len(unit)
                if group:groups.append(' '.join(group))
                return groups
            middle=len(chunk)//2
            return format_chunk(chunk[:middle],depth+1)+format_chunk(chunk[middle:],depth+1)
        paragraphs=[];group=[]
        for i,unit in enumerate(chunk,1):
            if i in breaks and group:paragraphs.append(' '.join(group));group=[]
            group.append(unit)
        if group:paragraphs.append(' '.join(group))
        return paragraphs
    paragraphs=[]
    for index,chunk in enumerate(chunks):
        paragraphs.extend(format_chunk(chunk))
        if progress:progress(index+1,len(chunks))
    result='\n\n'.join(paragraphs)
    if result.split()!=source_text(segments).split():raise ValueError('Разбиение изменило слова')
    return result
