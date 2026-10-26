import Foundation
import Combine
import AVFoundation
import ScreenCaptureKit
import CoreAudio

// Mutable audio buffers are confined to queue; capture-session changes to routeQueue.
final class Recorder:NSObject,@unchecked Sendable,SCStreamOutput,SCStreamDelegate,AVCaptureAudioDataOutputSampleBufferDelegate{
    var selectedSystemBundleID=""
    func selectSystemSource(_ bundleID:String)async throws{
        guard !stopping,let stream else{throw fail("Запись уже остановлена")}
        let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
        let filter=try SystemAudioDiscovery.filter(content,bundleID:bundleID)
        guard !stopping else{throw fail("Запись уже остановлена")}
        try await stream.updateContentFilter(filter)
        selectedSystemBundleID=bundleID
        queue.async{self.lastSystem=Date();self.journal()}
    }
    var onStatus:((String)->Void)?
    var selectedMicrophone:String="";var onMicrophone:((String)->Void)?
    func selectMicrophone(_ uid:String){routeQueue.async{self.selectedMicrophone=uid;do{try self.configureMicrophone()}catch{self.report("Не удалось переключить микрофон: "+error.localizedDescription)}}}
    var stream:SCStream?;var session:AVCaptureSession?;var micInput:AVCaptureDeviceInput?
    let queue=DispatchQueue(label:"calls.audio.samples");let routeQueue=DispatchQueue(label:"calls.audio.route")
    var files:[SCStreamOutputType:AVAudioFile]=[:];var paths:[SCStreamOutputType:URL]=[:];var first:[SCStreamOutputType:Double]=[:]
    var converter:AVAudioConverter?;var inputFormat:AVAudioFormat?;let fixed=AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
    var url:URL!;var mode="";var failure:String?;var onError:((String)->Void)?
    private let stopLock=NSLock();private var stopped=false
    var stopping:Bool{get{stopLock.lock();defer{stopLock.unlock()};return stopped}set{stopLock.lock();stopped=newValue;stopLock.unlock()}}
    var listener:AudioObjectPropertyListenerBlock?;var watchdog:DispatchSourceTimer?;var lastMic=Date();var lastSystem=Date();var micEnd=0.0;var systemEnd=0.0
    var devicesAddress=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultInputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    func fail(_ text:String)->NSError{NSError(domain:"Rehear",code:1,userInfo:[NSLocalizedDescriptionKey:text])}
    func report(_ message:String){queue.async{if !self.stopping && self.failure==nil{self.failure=message;self.onError?(message)}}}
    func journal(resolved:Bool=false){
        guard let url else{return}
        let file=url.deletingPathExtension().appendingPathExtension("session.json")
        let value:[String:Any]=["mode":mode,"systemSource":selectedSystemBundleID,"resolved":resolved,"offset":(first[.microphone] ?? 0)-(first[.audio] ?? 0)]
        if let data=try? JSONSerialization.data(withJSONObject:value){try? data.write(to:file,options:.atomic)}
    }
    func start(mode:String,url:URL)async throws{
        self.mode=mode;self.url=url
        journal()
        paths[.audio]=url.deletingPathExtension().appendingPathExtension("system.caf")
        paths[.microphone]=url.deletingPathExtension().appendingPathExtension("mic.caf")
        do{
            if mode != "system"{
                guard await AVCaptureDevice.requestAccess(for:.audio) else{throw fail("Разреши доступ к микрофону в настройках macOS.")}
                try await withCheckedThrowingContinuation{(continuation:CheckedContinuation<Void,Error>) in routeQueue.async{do{try self.configureMicrophone();continuation.resume()}catch{continuation.resume(throwing:error)}}}
                let block:AudioObjectPropertyListenerBlock = {[weak self] _,_ in guard let self,!self.stopping else{return};do{try self.configureMicrophone()}catch{self.report("Не удалось переключить микрофон: "+error.localizedDescription)}}
                listener=block
                AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),&devicesAddress,routeQueue,block)
                guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),&address,routeQueue,block)==noErr else{throw fail("Не удалось включить отслеживание микрофона")}
            }
            if mode != "mic"{
                let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
                let filter=try SystemAudioDiscovery.filter(content,bundleID:selectedSystemBundleID)
                let config=SCStreamConfiguration();config.width=2;config.height=2;config.minimumFrameInterval=CMTime(value:1,timescale:1);config.capturesAudio=true;config.excludesCurrentProcessAudio=true;config.sampleRate=48000;config.channelCount=2
                let s=SCStream(filter:filter,configuration:config,delegate:self);stream=s
                try s.addStreamOutput(self,type:.audio,sampleHandlerQueue:queue);try await s.startCapture()
            }
            queue.async{self.lastMic=Date();self.lastSystem=Date()}
            let timer=DispatchSource.makeTimerSource(queue:queue);timer.schedule(deadline:.now()+12,repeating:3)
            timer.setEventHandler{[weak self] in
                guard let self,!self.stopping else{return}
                if self.mode != "system" && Date().timeIntervalSince(self.lastMic)>10{self.report("Микрофон перестал передавать звук. Запись остановлена; полученные дорожки сохранены.")}
                if self.mode != "mic"{self.onStatus?(Date().timeIntervalSince(self.lastSystem)>12 ? "Нет данных системного звука · проверь источник":"Системный звук поступает")}
                if let attrs=try? FileManager.default.attributesOfFileSystem(forPath:url.deletingLastPathComponent().path),let free=attrs[.systemFreeSize] as? NSNumber,free.int64Value<128*1024*1024{self.report("Заканчивается место на диске. Сохраняем полученную запись; дорожки останутся для восстановления.")}
            }
            watchdog=timer;timer.resume()
            if let message=queue.sync(execute:{failure}){throw fail(message)}
        }catch{await cleanup();throw error}
    }
    // The macOS default input is the user's current system choice, not a guessed device.
    func configureMicrophone()throws{
        let devices=AVCaptureDevice.DiscoverySession(deviceTypes:[.microphone,.external],mediaType:.audio,position:.unspecified).devices
        guard let device=(devices.first{$0.uniqueID==selectedMicrophone} ?? AVCaptureDevice.default(for:.audio)) else{throw fail("Доступный микрофон не найден")}
        if micInput?.device.uniqueID==device.uniqueID,session?.isRunning==true{return}
        let input=try AVCaptureDeviceInput(device:device)
        let capture=session ?? AVCaptureSession();capture.beginConfiguration()
        if let old=micInput{capture.removeInput(old)}
        guard capture.canAddInput(input) else{if let old=micInput,capture.canAddInput(old){capture.addInput(old)};capture.commitConfiguration();throw fail("Не удалось подключить микрофон "+device.localizedName)}
        capture.addInput(input)
        if session==nil{
            let output=AVCaptureAudioDataOutput();output.setSampleBufferDelegate(self,queue:queue)
            guard capture.canAddOutput(output) else{capture.commitConfiguration();throw fail("Не удалось настроить запись микрофона")};capture.addOutput(output)
        }
        capture.commitConfiguration();session=capture;micInput=input
        if !capture.isRunning{capture.startRunning()};onMicrophone?(device.localizedName)
    }
    func captureOutput(_ output:AVCaptureOutput,didOutput sample:CMSampleBuffer,from connection:AVCaptureConnection){write(sample,.microphone)}
    func stream(_ stream:SCStream,didOutputSampleBuffer sample:CMSampleBuffer,of type:SCStreamOutputType){if type == .audio{write(sample,.audio)}}
    func stream(_ stream:SCStream,didStopWithError error:Error){report("Запись прервалась: "+error.localizedDescription)}
    func write(_ sample:CMSampleBuffer,_ type:SCStreamOutputType){
        guard !stopping,sample.isValid,CMSampleBufferGetNumSamples(sample)>0,let desc=CMSampleBufferGetFormatDescription(sample),let path=paths[type] else{return}
        do{
            let format=AVAudioFormat(cmAudioFormatDescription:desc)
            let list=AudioBufferList.allocate(maximumBuffers:Int(format.channelCount));defer{list.unsafeMutablePointer.deallocate()}
            var block:CMBlockBuffer?
            let status=CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample,bufferListSizeNeededOut:nil,bufferListOut:list.unsafeMutablePointer,bufferListSize:MemoryLayout<AudioBufferList>.size+(Int(format.channelCount)-1)*MemoryLayout<AudioBuffer>.size,blockBufferAllocator:kCFAllocatorDefault,blockBufferMemoryAllocator:kCFAllocatorDefault,flags:UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),blockBufferOut:&block)
            guard status==noErr,let pcm=AVAudioPCMBuffer(pcmFormat:format,bufferListNoCopy:list.unsafePointer,deallocator:nil) else{throw fail("Не удалось прочитать аудиобуфер")}
            let pts=CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if first[type]==nil{first[type]=pts;journal()}
            if type == .microphone{
                lastMic=Date()
                if inputFormat != format{converter=AVAudioConverter(from:format,to:fixed);inputFormat=format}
                guard let converter else{throw fail("Не удалось преобразовать формат микрофона")}
                let capacity=AVAudioFrameCount(ceil(Double(pcm.frameLength)*48000/format.sampleRate)+1024)
                guard let converted=AVAudioPCMBuffer(pcmFormat:fixed,frameCapacity:capacity) else{throw fail("Недостаточно памяти для звука")}
                var supplied=false;var error:NSError?
                let result=converter.convert(to:converted,error:&error){_,status in if supplied{status.pointee = .noDataNow;return nil};supplied=true;status.pointee = .haveData;return pcm}
                if result == .error{throw error ?? fail("Ошибка преобразования микрофона")}
                if files[type]==nil{files[type]=try AVAudioFile(forWriting:path,settings:fixed.settings)}
                // Keep timing through route changes: fill only the actual missing interval.
                let elapsed=max(0,pts-(first[type] ?? pts));var gap=Int(max(0,elapsed-micEnd)*48000)
                if gap>480{while gap>0{let n=min(gap,48000);let silence=AVAudioPCMBuffer(pcmFormat:fixed,frameCapacity:AVAudioFrameCount(n))!;silence.frameLength=AVAudioFrameCount(n);memset(silence.floatChannelData![0],0,n*MemoryLayout<Float>.size);try files[type]?.write(from:silence);gap-=n};micEnd=elapsed}
                try files[type]?.write(from:converted);micEnd += Double(converted.frameLength)/48000
            }else{
                lastSystem=Date();if files[type]==nil{files[type]=try AVAudioFile(forWriting:path,settings:format.settings,commonFormat:format.commonFormat,interleaved:format.isInterleaved)}
                let elapsed=max(0,pts-(first[type] ?? pts));var gap=Int(max(0,elapsed-systemEnd)*format.sampleRate)
                if gap>Int(format.sampleRate*0.01){
                    while gap>0{let n=min(gap,Int(format.sampleRate));guard let silence=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(n)) else{throw fail("Недостаточно памяти для системного звука")};silence.frameLength=AVAudioFrameCount(n);for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList){if let data=buffer.mData{memset(data,0,Int(buffer.mDataByteSize))}};try files[type]?.write(from:silence);gap-=n};systemEnd=elapsed
                }
                try files[type]?.write(from:pcm);systemEnd += Double(pcm.frameLength)/format.sampleRate
            }
        }catch{report("Ошибка записи: "+error.localizedDescription)}
    }
    func cleanup()async{
        stopping=true
        watchdog?.cancel();watchdog=nil
        if let listener{AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),&devicesAddress,routeQueue,listener);AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),&address,routeQueue,listener);self.listener=nil}
        await withCheckedContinuation{(continuation:CheckedContinuation<Void,Never>) in routeQueue.async{self.session?.stopRunning();self.session=nil;self.micInput=nil;continuation.resume()}}
        try? await stream?.stopCapture();stream=nil
        queue.sync{stopping=true;files.removeAll()}
    }
    func stop()async throws{
        await cleanup()
        let system=paths[.audio]!,mic=paths[.microphone]!
        var inputs:[URL]=[]
        if mode != "mic" && FileManager.default.fileExists(atPath:system.path){inputs.append(system)}
        if mode != "system" && FileManager.default.fileExists(atPath:mic.path){inputs.append(mic)}
        guard !inputs.isEmpty else{throw fail("Аудиоданные не поступали. Проверь разрешения и микрофон.")}
        var args=["-nostdin","-y"]
        for input in inputs{args += ["-i",input.path]}
        if inputs.count==2{let offset=(first[.microphone] ?? 0)-(first[.audio] ?? 0);let a=max(0,Int(-offset*1000)),b=max(0,Int(offset*1000));args += ["-filter_complex","[0:a]adelay=\(a):all=1[a];[1:a]adelay=\(b):all=1[b];[a][b]amix=inputs=2:duration=longest:normalize=0,alimiter=limit=0.95[out]","-map","[out]"]}
        args += ["-c:a","aac","-b:a","160k",url.path]
        let p=Process();p.executableURL=Bundle.main.resourceURL!.appendingPathComponent("ffmpeg");p.arguments=args;p.standardOutput=FileHandle.nullDevice
        let log=url.deletingPathExtension().appendingPathExtension("recording.log");FileManager.default.createFile(atPath:log.path,contents:nil);let handle=try FileHandle(forWritingTo:log);p.standardError=handle
        try p.run();await withCheckedContinuation{continuation in DispatchQueue.global().async{p.waitUntilExit();continuation.resume()}};try? handle.close()
        guard p.terminationStatus==0 else{throw fail("Не удалось собрать запись. Исходные дорожки сохранены рядом.")}
        let incomplete=(mode=="both" && inputs.count<2)
        if failure==nil && !incomplete{journal(resolved:true);for path in inputs{try? FileManager.default.removeItem(at:path)};try? FileManager.default.removeItem(at:log)}
        if let failure{throw fail("Полученная часть записи сохранена. "+failure)}
        if incomplete{throw fail("Запись сохранена, но одна из дорожек не поступала. Исходники оставлены рядом.")}
    }
}

struct AudioRoute:Identifiable,Equatable{var id:AudioDeviceID;var uid:String;var name:String}
@MainActor final class AudioRoutes:ObservableObject{
    @Published var inputs:[AudioRoute]=[];@Published var outputs:[AudioRoute]=[]
    @Published var microphone="";@Published var actualMicrophone="";@Published var outputName="";@Published var outputID:AudioDeviceID=0
    var timer:Timer?
    init(){refresh();timer=Timer.scheduledTimer(withTimeInterval:2,repeats:true){[weak self] _ in Task{@MainActor in self?.refresh()}}}
    func defaultDevice(_ selector:AudioObjectPropertySelector)->AudioDeviceID{var a=AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain);var id:AudioDeviceID=0;var n:UInt32=4;AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&n,&id);return id}
    func string(_ id:AudioDeviceID,_ selector:AudioObjectPropertySelector)->String{var a=AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain);var value:Unmanaged<CFString>?;var n=UInt32(MemoryLayout<Unmanaged<CFString>?>.size);guard AudioObjectGetPropertyData(id,&a,0,nil,&n,&value)==noErr else{return ""};return value?.takeUnretainedValue() as String? ?? ""}
    func hasStreams(_ id:AudioDeviceID,_ scope:AudioObjectPropertyScope)->Bool{var a=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreams,mScope:scope,mElement:kAudioObjectPropertyElementMain);var n:UInt32=0;return AudioObjectGetPropertyDataSize(id,&a,0,nil,&n)==noErr && n>0}
    func refresh(){
        var a=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain);var n:UInt32=0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&n)==noErr else{return}
        var ids=[AudioDeviceID](repeating:0,count:Int(n)/4);guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&n,&ids)==noErr else{return}
        let all=ids.map{AudioRoute(id:$0,uid:string($0,kAudioDevicePropertyDeviceUID),name:string($0,kAudioObjectPropertyName))}
        let ins=all.filter{hasStreams($0.id,kAudioDevicePropertyScopeInput)},outs=all.filter{hasStreams($0.id,kAudioDevicePropertyScopeOutput)}
        if inputs != ins{inputs=ins};if outputs != outs{outputs=outs}
        let id=defaultDevice(kAudioHardwarePropertyDefaultOutputDevice);if outputID != id{outputID=id};let name=outs.first{$0.id==id}?.name ?? "Системный звук";if outputName != name{outputName=name}
    }
    var microphoneName:String{inputs.first{$0.uid==microphone}?.name ?? inputs.first{$0.id==defaultDevice(kAudioHardwarePropertyDefaultInputDevice)}?.name ?? "Нет микрофона"}
    func chooseOutput(_ id:AudioDeviceID)throws{var a=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultOutputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain);var value=id;guard AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,4,&value)==noErr else{throw NSError(domain:"AudioRoutes",code:1,userInfo:[NSLocalizedDescriptionKey:"Не удалось переключить выход звука"])};refresh()}
}
