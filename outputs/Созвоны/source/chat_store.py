"""Atomic per-conversation chat; messages have independent identities."""
import json,uuid
from pathlib import Path

def load(folder):
    folder=Path(folder);file=folder/'.chat.json'
    if file.exists():return json.loads(file.read_text())
    try:old=json.loads((folder/'.questions.json').read_text())
    except (OSError,ValueError):old=[]
    messages=[]
    for item in old:
        key=item['id'];messages.extend([
            dict(id=key+':user',role='user',text=item['question'],sources=[]),
            dict(id=key+':assistant',role='assistant',text=item['answer'],replyTo=key+':user',sources=item.get('sources',[]),revision=item.get('revision',''),status='done')])
    return {'version':1,'hideSummary':False,'messages':messages}

def save(folder,chat):
    file=Path(folder)/'.chat.json';tmp=file.with_suffix('.tmp')
    tmp.write_text(json.dumps(chat,ensure_ascii=False,indent=2));tmp.replace(file)

def add_question(folder,question):
    chat=load(folder);user=uuid.uuid4().hex;answer=uuid.uuid4().hex
    chat['messages'].extend([dict(id=user,role='user',text=question,sources=[]),dict(id=answer,role='assistant',text='',sources=[],replyTo=user,status='queued')]);save(folder,chat)
    return user,answer

def regenerate(folder,key):
    chat=load(folder);message=next((m for m in chat['messages'] if m['id']==key and m['role']=='assistant'),None)
    if not message:raise ValueError('Ответ уже удалён')
    user=next((m for m in chat['messages'] if m['id']==message.get('replyTo') and m['role']=='user'),None)
    if not user:raise ValueError('Исходное сообщение удалено. Отправь вопрос заново.')
    message['status']='queued';save(folder,chat);return user['id'],user['text']

def delete(folder,key):
    chat=load(folder)
    if key=='summary':chat['hideSummary']=True
    else:chat['messages']=[m for m in chat['messages'] if m['id']!=key]
    save(folder,chat)

def complete(folder,key,text,sources,revision):
    chat=load(folder);message=next((m for m in chat['messages'] if m['id']==key),None)
    if not message:raise InterruptedError()
    if not any(m['id']==message.get('replyTo') for m in chat['messages']):raise InterruptedError()
    message.update(text=text,sources=sources,revision=revision,status='done');save(folder,chat)

def status(folder,key,status):
    chat=load(folder)
    for message in chat['messages']:
        if message['id']==key:message['status']=status
    save(folder,chat)
