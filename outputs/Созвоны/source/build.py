#!/usr/bin/env python3
"""Пересобрать приложение после правок Swift/Python; модели остаются локальными."""
import pathlib,subprocess,shutil,tempfile,plistlib
from sign import sign
from bundle_runtime import bundle_runtime
from compatibility import check,MINIMUM
source=pathlib.Path(__file__).resolve().parent
app=source.parent/'Созвоны.app'
with tempfile.TemporaryDirectory(prefix='calls-build-') as scratch:
    staged=pathlib.Path(scratch)/app.name
    shutil.copytree(app,staged)
    subprocess.run(['swiftc','-module-cache-path',str(pathlib.Path(scratch)/'module-cache'),'-parse-as-library',str(source/'App.swift'),str(source/'FileTools.swift'),str(source/'NativeReader.swift'),str(source/'Recorder.swift'),str(source/'SystemAudioSources.swift'),str(source/'ConversationUI.swift'),str(source/'SetupUI.swift'),'-o',str(staged/'Contents/MacOS/Calls'),'-framework','SwiftUI','-framework','ScreenCaptureKit','-framework','AVFoundation','-framework','WebKit','-framework','ServiceManagement','-target','arm64-apple-macosx15.0'],check=True)
    shutil.copy2(source/'engine.py',staged/'Contents/Resources/engine.py')
    shutil.copy2(source/'transcript.py',staged/'Contents/Resources/transcript.py')
    shutil.copy2(source/'storage.py',staged/'Contents/Resources/storage.py')
    shutil.copy2(source/'chat_store.py',staged/'Contents/Resources/chat_store.py')
    shutil.copy2(source/'conversation_features.py',staged/'Contents/Resources/conversation_features.py')
    shutil.copy2(source/'library_tools.py',staged/'Contents/Resources/library_tools.py')
    shutil.copy2(source/'relocation.py',staged/'Contents/Resources/relocation.py')
    subprocess.run(['swiftc','-module-cache-path',str(pathlib.Path(scratch)/'module-cache'),'-parse-as-library',str(source/'FileLocator.swift'),'-o',str(staged/'Contents/Resources/FileLocator'),'-target','arm64-apple-macosx15.0'],check=True)
    for cache in staged.rglob("__pycache__"):shutil.rmtree(cache)
    subprocess.run(['xattr','-cr',str(staged)],check=True)
    subprocess.run(['swiftc','-module-cache-path',str(pathlib.Path(scratch)/'module-cache'),'-parse-as-library',str(source/'ConvertHelper.swift'),'-o',str(staged/'Contents/Resources/FileConverter'),'-framework','AppKit','-framework','ImageIO','-framework','CoreText','-framework','UniformTypeIdentifiers','-target','arm64-apple-macosx15.0'],check=True)
    for name in ['model_downloads.py','model_downloads.json','plain_text.py','paragraph_session.py','transcription_guard.py','transcript_versions.py','reliability.py','recording_recovery.py']:shutil.copy2(source/name,staged/'Contents/Resources'/name)
    bundle_runtime(staged)
    info=staged/'Contents/Info.plist';metadata=plistlib.loads(info.read_bytes());metadata['LSMinimumSystemVersion']=MINIMUM;info.write_bytes(plistlib.dumps(metadata))
    check(staged)
    sign(staged)
    shutil.rmtree(app)
    shutil.copytree(staged,app)
    shutil.copy2(staged/'Contents/MacOS/Calls',source.parents[2]/'work/Calls-ux')
    package=source.parent/'Созвоны.zip'
    if package.exists():package.unlink()
    subprocess.run(['ditto','-c','-k','--keepParent','--norsrc',str(staged),str(package)],check=True)
print('Пересобрано:',app)
