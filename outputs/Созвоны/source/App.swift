import SwiftUI
import AppKit
import ScreenCaptureKit
import AVFoundation
import WebKit
import ServiceManagement
import UniformTypeIdentifiers

struct MergePart:Codable,Hashable{var id:String;var revision:String}
struct Call: Codable, Identifiable, Hashable {
    var id:String;var path:String;var name:String;var status:String;var message:String;var output:String;var progress:Double
    var parts:[MergePart]?
    var size:Int64?;var modified:Double?;var created:Double?;var dateSortValue:Double?;var stable:Bool?
    var dateKey:Double{dateSortValue ?? 0}
    var title:String?;var kind:String?;var parentId:String?;var missing:Bool?;var resultMissing:Bool?;var removable:Bool?;var summaryReady:Bool?;var chatMessageId:String?
    var label:String { if kind=="paragraphs"{return status=="done" ? "Текст готов":status=="working" ? "Разбиение на абзацы":status=="queued" ? "Текст · в очереди":status=="error" ? "Ошибка разбиения":"Отменено"}; if kind=="qa" && status=="working"{return "Ответ на вопрос"};if kind=="summary" && status=="working"{return "Краткое содержание"};if missing==true && !["queued","working","converting","naming"].contains(status){return "Не найдено"};return ["waitingModel":"Нужна модель","new":"Новый","queued":"В очереди","converting":"Подготовка","working":"Транскрибация","naming":"Название","done":"Готово","error":"Ошибка","cancelled":"Отменено"][status] ?? status }
}
struct LocalModel:Decodable,Identifiable{var path:String;var name:String;var id:String{path}}
struct ModelCatalog:Decodable{var speech:[LocalModel];var llm:[LocalModel]}
struct Snapshot:Decodable { var type:String;var folder:String;var naming:Bool;var language:String;var quality:String;var glossary:String;var vad:Bool;var files:[Call];var jobs:[Call];var error:String;var ready:Bool;var speechModel:String;var titleModel:String;var titleTemplate:String;var models:ModelCatalog;var queuePaused:Bool?;var downloads:[DownloadModel]?;var recoveries:[RecoveryRecording]?;var stateNotice:String?;var lastFailure:FailureRecord? }
struct Reader:Identifiable {var id=UUID();var path:String;var txt:String;var title:String;var jobId:String="";var seek:Double?=nil;var query:String="";var page:Int=0}
struct SearchHit:Decodable,Identifiable{var jobId:String;var title:String;var start:Double?;var text:String;var id:String{jobId+":"+String(start ?? -1)}}
@MainActor final class Store:ObservableObject {
    @Published var recoveries:[RecoveryRecording]=[];@Published var stateNotice="";@Published var lastFailure:FailureRecord?
    @Published var serviceHealthy=false;@Published var systemActivity="";@Published var versions:[TranscriptVersion]=[];@Published var versionsJob=""
    var serviceWarned=false;var shuttingDown=false;var sleepObserver:NSObjectProtocol?;var lastBackend=Date();var lastProbe=Date()
    func serviceFailure(_ message:String){
        error=message
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:400,height:140),styleMask:[.titled,.closable,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.title="Обработка требует внимания";panel.level = .floating;panel.isReleasedWhenClosed=false
        panel.contentView=NSHostingView(rootView:VStack(alignment:.leading,spacing:12){Text(message).font(.callout);HStack{Button("Перезапустить"){panel.close();self.restartService()}.disabled(self.recording || self.startingRecording);Spacer();Button("Закрыть"){panel.close()}}}.padding(18).frame(width:400).preferredColorScheme(.dark))
        recordingAlert?.close();recordingAlert=panel;panel.orderFrontRegardless()
    }
    func restartService(){
        guard !recording && !startingRecording else{error="Перезапуск обработки доступен после остановки записи";return}
        shuttingDown=true;timer?.invalidate();try? input?.fileHandleForWriting.close()
        let old=process;old?.terminate()
        Task{while old?.isRunning==true{try? await Task.sleep(for:.milliseconds(100))};shuttingDown=false;start()}
    }
    func copyDiagnostics(){
        let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "?"
        var text="Rehear \(version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · RAM \(ProcessInfo.processInfo.physicalMemory/1024/1024/1024) ГБ · ARM64\nТранскрибация: \(URL(fileURLWithPath:speechModel).lastPathComponent)\nLLM: \(URL(fileURLWithPath:titleModel).lastPathComponent)\nМикрофон: \(AVCaptureDevice.authorizationStatus(for:.audio).rawValue) · Системный звук: \(CGPreflightScreenCaptureAccess())\nСервис: \(serviceHealthy ? "доступен":"недоступен") · В очереди: \(jobs.filter{["queued","working","waitingModel"].contains($0.status)}.count)"
        if let issue=lastFailure{text += "\nПоследний сбой: \(issue.time) · этап \(issue.stage) · код \(issue.code) · тип \(issue.kind)"}
        NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)
    }
    @Published var downloads:[DownloadModel]=[]
    @Published var files:[Call]=[];@Published var jobs:[Call]=[];@Published var folder="";@Published var naming=true;@Published var ready=false
    var openMain:(()->Void)?;@Published var externalQueueToken=0
    var transcriptWindows:[UUID:TranscriptWindowController]=[:];@Published var language="ru";@Published var quality="precise";@Published var glossary="";@Published var vad=true
    @Published var speechModel="";@Published var titleModel="";@Published var titleTemplate="chatml";@Published var models=ModelCatalog(speech:[],llm:[])
    @Published var batchNotice="";@Published var error="";@Published var recording=false;@Published var startingRecording=false;@Published var recordingStatus="";@Published var mode="both"
    @Published var recordingStarted:Date?;let audioRoutes=AudioRoutes();let systemSources=SystemAudioSources()
    var recordingAlert:NSPanel?;var finishingRecording=false
    func recordingFailure(_ message:String){
        if process?.isRunning==true{send(["action":"reportRecordingFailure"])}
        error=message;recordingAlert?.close()
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:380,height:130),styleMask:[.titled,.closable,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.title="Сбой записи";panel.level = .floating;panel.isReleasedWhenClosed=false
        panel.contentView=NSHostingView(rootView:VStack(alignment:.leading,spacing:12){Label("Запись требует внимания",systemImage:"exclamationmark.triangle").font(.headline);Text(message).font(.callout).lineLimit(4);HStack{Spacer();Button("Закрыть"){panel.close()}}}.padding(18).frame(width:380).preferredColorScheme(.dark))
        if let frame=NSScreen.main?.visibleFrame{panel.setFrameOrigin(NSPoint(x:frame.maxX-400,y:frame.minY+22))};recordingAlert=panel;panel.orderFrontRegardless()
    }
    var process:Process?;var input:Pipe?;var timer:Timer?;var recorder:Recorder?;var recordURL:URL?
    @Published var searchHits:[SearchHit]=[];@Published var searchQuery="";@Published var searchBusy=false;@Published var queuePaused=false
    @Published var editRevision=0;var editedJob=""
    var searchTask:Task<Void,Never>?
    func search(_ query:String){searchTask?.cancel();searchQuery=query;searchHits=[];searchBusy = !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty;guard searchBusy else{return};searchTask=Task{try? await Task.sleep(for:.milliseconds(250));guard !Task.isCancelled else{return};send(["action":"search","query":query])}}
    @Published var durations:[String:Double]=[:]
    var durationKeys:[String:String]=[:];var durationTask:Task<Void,Never>?
    func loadDurations(){
        guard durationTask==nil else{return}
        durationTask=Task{defer{durationTask=nil}
            var seen=Set<String>()
            for row in jobs+files where seen.insert(row.id).inserted && row.kind != "qa" && row.kind != "summary"{
                let playback=URL(fileURLWithPath:row.output).appendingPathComponent(".playback.m4a")
                let url=FileManager.default.fileExists(atPath:playback.path) ? playback:URL(fileURLWithPath:row.path)
                guard let attrs=try? FileManager.default.attributesOfItem(atPath:url.path) else{continue}
                let key=url.path+String(describing:attrs[.size])+String(describing:attrs[.modificationDate])
                guard durationKeys[row.id] != key else{continue};durationKeys[row.id]=key
                if let duration=try? await AVURLAsset(url:url).load(.duration){let seconds=duration.seconds;if seconds.isFinite && seconds>0{durations[row.id]=seconds}}
            }
        }
    }
    func durationLabel(_ row:Call)->String{durations[row.id].map{compactDuration($0)} ?? ""}
    init(){
        start()
        sleepObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main){[weak self] _ in Task{@MainActor in guard let self,self.recording else{return};await self.finishRecording();self.batchNotice="Запись сохранена перед сном Mac"}}
    }
    func start(){
        lastBackend=Date();lastProbe=Date();serviceHealthy=false;serviceWarned=false
        let p=Process();let out=Pipe();let inp=Pipe();let err=Pipe();input=inp
        p.executableURL=Bundle.main.resourceURL!.appendingPathComponent("python/bin/python3")
        var environment=ProcessInfo.processInfo.environment;environment["PYTHONHOME"]=Bundle.main.resourceURL!.appendingPathComponent("python").path;environment["PYTHONNOUSERSITE"]="1";environment["PYTHONPATH"]=nil;p.environment=environment
        p.arguments=["-B",Bundle.main.resourceURL!.appendingPathComponent("engine.py").path];p.standardInput=inp;p.standardOutput=out;p.standardError=err
        var buffer=Data(); let decodeQueue=DispatchQueue(label:"calls.decode")
        out.fileHandleForReading.readabilityHandler={h in
            let chunk=h.availableData
            if chunk.isEmpty{return}
            decodeQueue.async {
                buffer.append(chunk)
                while let r=buffer.range(of:Data([10])) {
                    let line=buffer.subdata(in:0..<r.lowerBound);buffer.removeSubrange(0..<r.upperBound)
                    if let s=try? JSONDecoder().decode(Snapshot.self,from:line) {
                        Task{@MainActor in self.lastBackend=Date();self.serviceHealthy=true;if self.serviceWarned && self.error.hasPrefix("Сервис обработки не отвечает"){self.error="";self.recordingAlert?.close()};self.serviceWarned=false;self.recoveries=s.recoveries ?? [];self.stateNotice=s.stateNotice ?? "";self.lastFailure=s.lastFailure;self.queuePaused=s.queuePaused ?? false;self.downloads=s.downloads ?? [];self.files=s.files;self.jobs=s.jobs;self.loadDurations();self.folder=s.folder;self.naming=s.naming;self.language=s.language;self.quality=s.quality;self.glossary=s.glossary;self.vad=s.vad;self.ready=s.ready;self.speechModel=s.speechModel;self.titleModel=s.titleModel;self.titleTemplate=s.titleTemplate;self.models=s.models;if !s.error.isEmpty{self.error=s.error}}
                    }else if let value=try? JSONSerialization.jsonObject(with:line) as? [String:Any]{
                        if value["type"] as? String == "reader",let path=value["path"] as? String {let txt=value["txt"] as? String ?? "";let title=value["title"] as? String ?? "Транскрипт";Task{@MainActor in self.openReader(Reader(path:path,txt:txt,title:title,jobId:value["jobId"] as? String ?? "",seek:value["seek"] as? Double,query:value["query"] as? String ?? "",page:value["page"] as? Int ?? 0))}}
                        else if value["type"] as? String=="search",let data=try? JSONSerialization.data(withJSONObject:value["hits"] ?? []),let hits=try? JSONDecoder().decode([SearchHit].self,from:data){let q=value["query"] as? String ?? "";Task{@MainActor in if self.searchQuery==q{self.searchHits=hits;self.searchBusy=false}}}
                        else if value["type"] as? String=="edited"{let id=value["jobId"] as? String ?? "";Task{@MainActor in self.editedJob=id;self.editRevision += 1;self.search(self.searchQuery)}}
                        else if value["type"] as? String=="versionHistory",let data=try? JSONSerialization.data(withJSONObject:value["versions"] ?? []),let rows=try? JSONDecoder().decode([TranscriptVersion].self,from:data){Task{@MainActor in self.versions=rows;self.versionsJob=value["jobId"] as? String ?? ""}}
                        else if value["type"] as? String=="recordingQueued",let message=value["message"] as? String{Task{@MainActor in self.recordingStatus=message;self.batchNotice=message}}
                        else if value["type"] as? String=="batch",let message=value["message"] as? String{Task{@MainActor in self.batchNotice=message}}
                        else if let message=value["message"] as? String{Task{@MainActor in self.error=message}}
                    }
                }
            }
        }
        err.fileHandleForReading.readabilityHandler={h in let data=h.availableData;if !data.isEmpty{let text=String(decoding:data,as:UTF8.self);Task{@MainActor in self.error=text}}}
        p.terminationHandler={[weak self] process in Task{@MainActor in guard let self,!self.shuttingDown,self.process===process else{return};self.serviceHealthy=false;self.serviceFailure("Обработка остановилась. Записи сохранены; можно перезапустить обработчик.")}}
        do{try p.run();process=p}catch{self.error=error.localizedDescription}
        timer=Timer.scheduledTimer(withTimeInterval:5,repeats:true){_ in Task{@MainActor in let now=Date();if now.timeIntervalSince(self.lastProbe)>12{self.lastBackend=now};self.lastProbe=now;if !self.serviceWarned && now.timeIntervalSince(self.lastBackend)>60{self.serviceWarned=true;self.serviceHealthy=false;self.serviceFailure("Сервис обработки не отвечает. Можно перезапустить обработчик; исходные записи сохранятся.")};if self.process?.isRunning==true{self.send(["action":"scan"])}}}
    }
    func enqueueFiles(_ urls:[URL]){
        send(["action":"enqueuePaths","paths":urls.filter{$0.isFileURL}.map{$0.path}])
        externalQueueToken += 1;openMain?();NSApp.activate(ignoringOtherApps:true)
    }
    func openReader(_ reader:Reader){
        let folder=URL(fileURLWithPath:reader.path).deletingLastPathComponent().path
        if let existing=transcriptWindows.values.first(where:{$0.resultFolder==folder}){existing.model.navigate(reader.seek,reader.query,reader.page);existing.showWindow(nil);existing.window?.makeKeyAndOrderFront(nil);return}
        let controller=TranscriptWindowController(reader:reader,store:self)
        controller.onClose={[weak self] in self?.transcriptWindows.removeValue(forKey:reader.id)}
        transcriptWindows[reader.id]=controller;controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)
    }
    func isExternal(_ row:Call)->Bool{
        let root=URL(fileURLWithPath:folder).resolvingSymlinksInPath().standardizedFileURL.path
        let path=URL(fileURLWithPath:row.path).resolvingSymlinksInPath().standardizedFileURL.path
        return path != root && !path.hasPrefix(root+"/")
    }
    func canRemove(_ row:Call)->Bool{row.removable ?? isExternal(row)}
    func removeExternal(_ ids:Set<String>){
        let rows=jobs.filter{ids.contains($0.id)}
        guard !rows.isEmpty,rows.allSatisfy({canRemove($0)}) else{return}
        if rows.contains(where:{["converting","working","naming"].contains($0.status)}){
            let alert=NSAlert();alert.messageText="Остановить обработку и убрать из списка?";alert.informativeText="Исходные файлы и уже готовые результаты останутся на диске.";alert.addButton(withTitle:"Продолжить обработку");alert.addButton(withTitle:"Убрать из списка")
            guard alert.runModal() == .alertSecondButtonReturn else{return}
        }
        send(["action":"removeExternal","ids":Array(ids)])
    }
    func canDelete(_ row:Call)->Bool{
        let active=["queued","working","converting","naming"]
        return !active.contains(row.status) && row.kind != "summary" && row.kind != "qa" && row.kind != "merge" && !(row.kind=="improve" && row.status != "done") && !jobs.contains{active.contains($0.status) && ($0.parentId==row.id || $0.path==row.path || ($0.parts?.contains{$0.id==row.id} ?? false))}
    }
    func deleteCalls(_ rows:[Call]){
        guard !rows.isEmpty,rows.allSatisfy({canDelete($0)}) else{error="Сначала отмени обработку выбранных записей и связанные задания.";return}
        var targets:[(Call,URL?)]=[]
        do{
            for row in rows{
                let completed=row.status=="done" && !row.output.isEmpty
                let target=URL(fileURLWithPath:completed ? row.output:row.path)
                if !FileManager.default.fileExists(atPath:target.path){targets.append((row,nil));continue}
                if completed{
                    let data=try Data(contentsOf:target.appendingPathComponent(".calls-result.json"))
                    guard let meta=try JSONSerialization.jsonObject(with:data) as? [String:Any],meta["id"] as? String==row.id else{throw NSError(domain:"Calls",code:1,userInfo:[NSLocalizedDescriptionKey:"Не удалось подтвердить папку результата. Удаление отменено."])}
                }
                targets.append((row,target))
            }
        }catch{self.error=error.localizedDescription;return}
        let alert=NSAlert();alert.alertStyle = .warning;alert.messageText="Удалить выбранные записи (\(rows.count))?"
        alert.informativeText="Готовые созвоны будут перемещены в Корзину целиком: запись, транскрипты, саммари и улучшенные версии. Необработанные файлы тоже отправятся в Корзину. Уже отсутствующие записи будут убраны только из истории."
        alert.addButton(withTitle:"Отмена");alert.addButton(withTitle:"Переместить в Корзину")
        guard alert.runModal() == .alertSecondButtonReturn else{return}
        var removed=0;var failures:[String]=[];var handled:[URL]=[]
        for (row,target) in targets{
            do{
                if let target,!handled.contains(where:{target.path==$0.path || target.path.hasPrefix($0.path+"/")}){
                    for controller in Array(transcriptWindows.values){if controller.resultFolder==target.path || controller.resultFolder.hasPrefix(target.path+"/"){controller.window?.close()}}
                    try FileManager.default.trashItem(at:target,resultingItemURL:nil);handled.append(target)
                }
                send(["action":"forget","id":row.id]);removed+=1
            }catch{failures.append(error.localizedDescription)}
        }
        batchNotice="Удалено из списка: \(removed) из \(rows.count)"
        if !failures.isEmpty{error="Не удалось удалить часть записей: "+failures.joined(separator:"; ")}
    }
    func deleteCall(_ row:Call){
        guard canDelete(row) else{error="Сначала заверши или отмени связанные задания.";return}
        let active=["queued","converting","working","naming"]
        if jobs.contains(where:{$0.parentId==row.id && active.contains($0.status)}){error="Сначала отмени улучшение этой записи.";return}
        guard !active.contains(row.status) else{error="Сначала отмени обработку этой записи.";return}
        let completed=row.status=="done" && !row.output.isEmpty
        let target=URL(fileURLWithPath:completed ? row.output:row.path)
        let alert=NSAlert();alert.alertStyle = .warning
        alert.messageText=completed ? "Удалить папку транскрипта?":"Удалить запись созвона?"
        alert.informativeText=completed ? "В Корзину будет перемещена вся папка «\(target.lastPathComponent)» с транскриптом, просмотром и аудио для плеера. Запись внутри папки тоже будет перемещена в Корзину.":"Файл «\(target.lastPathComponent)» будет перемещён в Корзину."
        if row.kind=="improve"{alert.messageText="Удалить улучшенную версию?";alert.informativeText="В Корзину будет перемещена только эта версия транскрипта. Исходная запись и первый транскрипт сохранятся."}
        alert.addButton(withTitle:"Отмена");alert.addButton(withTitle:"Переместить в Корзину")
        guard alert.runModal() == .alertSecondButtonReturn else{return}
        do{
            guard FileManager.default.fileExists(atPath:target.path) else{throw NSError(domain:"Rehear",code:1,userInfo:[NSLocalizedDescriptionKey:"Файл или папка уже перемещены. Обнови список."])}
            if completed{
                let marker=target.appendingPathComponent(".calls-result.json")
                let data=try Data(contentsOf:marker)
                guard let meta=try JSONSerialization.jsonObject(with:data) as? [String:Any],meta["id"] as? String == row.id else{throw NSError(domain:"Rehear",code:1,userInfo:[NSLocalizedDescriptionKey:"Не удалось подтвердить папку результата. Удаление отменено."])}
                for controller in Array(transcriptWindows.values){if controller.resultFolder==target.path{controller.window?.close()}}
            }
            try FileManager.default.trashItem(at:target,resultingItemURL:nil)
            send(["action":"forget","id":row.id])
        }catch{self.error=error.localizedDescription}
    }
    func send(_ value:[String:Any]){guard let data=try? JSONSerialization.data(withJSONObject:value) else{return};do{try input?.fileHandleForWriting.write(contentsOf:data+Data([10]))}catch{self.error=error.localizedDescription}}
    func chooseFolder(){let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.prompt="Выбрать папку созвонов";if panel.runModal() == .OK,let url=panel.url{send(["action":"folder","path":url.path])}}
    func enqueue(_ ids:Set<String>){send(["action":"enqueue","ids":Array(ids)])}
    func selectSystemSource(_ id:String,_ name:String){
        guard !systemSources.changing else{return}
        if recording && mode != "mic",let recorder{
            systemSources.changing=true
            Task{defer{systemSources.changing=false};do{try await recorder.selectSystemSource(id);systemSources.selectedID=id;systemSources.selectedName=name}catch{self.error=error.localizedDescription}}
        }else{systemSources.selectedID=id;systemSources.selectedName=name}
    }
    func record(){
        if recording{Task{await finishRecording()};return}
        guard !folder.isEmpty else{return}
        guard process?.isRunning==true else{serviceFailure("Обработчик недоступен. Перезапусти его перед записью.");return}
        let d=URL(fileURLWithPath:folder).appendingPathComponent("Записи")
        do{try FileManager.default.createDirectory(at:d,withIntermediateDirectories:true)}catch{self.error=error.localizedDescription;return}
        let formatter=DateFormatter();formatter.dateFormat="yyyy-MM-dd HH-mm-ss"
        let url=d.appendingPathComponent("Созвон \(formatter.string(from:Date()))-\(UUID().uuidString.prefix(4)).m4a");recordURL=url
        if let attrs=try? FileManager.default.attributesOfFileSystem(forPath:d.path),let free=attrs[.systemFreeSize] as? NSNumber,free.int64Value<512*1024*1024{recordingFailure("Недостаточно места для записи. Освободи хотя бы 512 МБ.");return}
        send(["action":"registerRecording","path":url.path])
        let r=Recorder();r.selectedSystemBundleID=systemSources.selectedID;r.onStatus={message in Task{@MainActor in if self.systemActivity != message{self.systemActivity=message}}};r.selectedMicrophone=audioRoutes.microphone;r.onMicrophone={name in Task{@MainActor in self.audioRoutes.actualMicrophone=name}};recorder=r;startingRecording=true;recordingStatus="Запрашиваем доступ…"
        r.onError={message in Task{@MainActor in self.recordingFailure(message);if self.recording{await self.finishRecording()}}}
        Task{defer{startingRecording=false};do{try await r.start(mode:mode,url:url);recording=true;recordingStarted=Date();recordingStatus="Идёт запись · \(url.lastPathComponent)"}catch{self.recordingFailure(error.localizedDescription);recordingStatus="";recorder=nil;send(["action":"recordingStopped"])}}
    }
    func finishRecording()async{
        guard !finishingRecording else{return};finishingRecording=true;defer{finishingRecording=false}
        recordingStatus="Сохраняем запись…"
        do{try await recorder?.stop();if let url=recordURL{send(["action":"recordingSaved","path":url.path])};recordingStatus="Запись сохранена · проверяем очередь…"}catch{self.recordingFailure(error.localizedDescription);recordingStatus="Запись завершена с предупреждением"}
        recording=false;recordingStarted=nil;recorder=nil;systemActivity="";send(["action":"recordingStopped"]);send(["action":"scan"])
    }
    func shutdown(){shuttingDown=true;timer?.invalidate();try? input?.fileHandleForWriting.close();process?.waitUntilExit()}
}

struct ContentView:View{
    @Environment(\.openWindow) var openWindow
    @EnvironmentObject var store:Store
    @AppStorage("calls.setupCompleted") var setupCompleted=false
    @State var showSetup=false;@State var showReadiness=false
    @AppStorage("calls.dateField") var dateField="modified"
    @AppStorage("calls.dateNewestFirst") var dateNewestFirst=true
    @State var dateOrder=[KeyPathComparator(\Call.dateKey,order:.reverse)]
    @State var page=0;@State var selected=Set<String>();@State var query="";@State var dropHovered=false;@State var joinSelection:JoinSelection?
    let accent=Color(red:0.64,green:0.48,blue:0.96)
    let canvas=Color(red:0.075,green:0.075,blue:0.09)
    let surface=Color(red:0.12,green:0.12,blue:0.14)
    var all:[Call]{store.files+store.jobs.filter{job in !store.files.contains(where:{$0.id==job.id})}}
    var active:[Call]{store.jobs.filter{["queued","working","converting","naming","waitingModel"].contains($0.status)}}
    var newFiles:[Call]{all.filter{$0.status=="new"}}
    var rows:[Call]{
        let source: [Call]
        switch page{case 1:source=all.filter{$0.status != "done"};case 2:source=all.filter{$0.status != "done"}.sorted{a,b in let aa=["working","converting","naming","queued"].contains(a.status);let bb=["working","converting","naming","queued"].contains(b.status);return aa != bb ? aa: (a.modified ?? 0)>(b.modified ?? 0)};default:source=all.filter{$0.status=="done" && $0.kind==nil}}
        let filtered=query.isEmpty ? source:source.filter{($0.title ?? $0.name).localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query)}
        if page==2{
            let order=Dictionary(uniqueKeysWithValues:store.jobs.enumerated().map{($0.element.id,$0.offset)})
            func rank(_ row:Call)->Int{["working","converting","naming"].contains(row.status) ? 0:row.status=="queued" ? 1:2}
            return filtered.sorted{a,b in if rank(a) != rank(b){return rank(a)<rank(b)};if rank(a)<2{return (order[a.id] ?? Int.max)<(order[b.id] ?? Int.max)};return (a.modified ?? 0)>(b.modified ?? 0)}
        }
        return filtered.map{row in var copy=row;copy.dateSortValue=(dateField=="created" ? row.created:row.modified) ?? (dateOrder.first?.order == .reverse ? -Double.infinity:Double.infinity);return copy}.sorted{a,b in
            let result=dateOrder.first?.compare(a,b) ?? .orderedSame
            return result == .orderedSame ? a.id<b.id:result == .orderedAscending
        }
    }
    var removable:Set<String>{Set(rows.filter{selected.contains($0.id) && store.canRemove($0)}.map{$0.id})}
    var body:some View{
        HStack(spacing:0){
            VStack(alignment:.leading,spacing:6){
                HStack(spacing:10){Image(systemName:"waveform").font(.title2).foregroundStyle(accent);Text("Rehear").font(.title3.weight(.semibold))}.padding(.bottom,32).padding(.leading,12)
                nav("Главная","square.grid.2x2",0)
                nav("Очередь","list.bullet.rectangle",2,active.count+newFiles.count)
                nav("Транскрипты","doc.text",3)
                Spacer()
                nav("Настройки","slider.horizontal.3",4)
                Divider().padding(.vertical,12)
                Label(store.ready ? "Локальная обработка":"Модель недоступна",systemImage:store.ready ? "lock":"exclamationmark.triangle").font(.caption).foregroundStyle(.secondary).padding(.leading,12)
            }.padding(20).frame(width:210).background(Color.black.opacity(0.24))
            Rectangle().fill(Color.white.opacity(0.06)).frame(width:1)
            VStack(alignment:.leading,spacing:24){
                HStack{VStack(alignment:.leading,spacing:6){Text(["Главная","Входящие","Очередь","Транскрипты","Настройки"][page]).font(.system(size:28,weight:.semibold));Text(subtitle).font(.callout).foregroundStyle(.secondary)};Spacer();if page>0 && page<4{Button{store.send(["action":"scan"])}label:{Image(systemName:"arrow.clockwise")}.buttonStyle(.plain).help("Обновить список")}}
                if page==0{home}else if page==4{settings}else{library}
                if !store.batchNotice.isEmpty{HStack{Text(store.batchNotice).font(.caption).foregroundStyle(.secondary);Spacer();Button{store.batchNotice=""}label:{Image(systemName:"xmark")}.buttonStyle(.plain)}}
                if !store.error.isEmpty{HStack(alignment:.top){Image(systemName:"exclamationmark.circle");Text(store.error).textSelection(.enabled).lineLimit(3);Spacer();Button{store.error=""}label:{Image(systemName:"xmark")}.buttonStyle(.plain)}.font(.callout).foregroundStyle(.orange).padding(12).background(surface,in:RoundedRectangle(cornerRadius:10))}
            }.padding(32).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        }.background(canvas).tint(accent).preferredColorScheme(.dark).frame(minWidth:1020,minHeight:680)
        .onAppear{showSetup = !setupCompleted;dateOrder=[KeyPathComparator(\Call.dateKey,order:dateNewestFirst ? .reverse:.forward)];store.openMain={openWindow(id:"main")};if store.externalQueueToken>0{page=2}}
        .onChange(of:store.externalQueueToken){_,_ in page=2}
        .sheet(isPresented:$showReadiness){ReadinessView(store:store)}
        .sheet(isPresented:$showSetup){SetupSheet(store:store,completed:$setupCompleted)}
        .sheet(item:$joinSelection){selection in JoinConversationsSheet(store:store,parts:selection.parts)}
        .onChange(of:dateOrder){_,value in dateNewestFirst=value.first?.order == .reverse}
        .onChange(of:page){_,_ in selected=[];query="";store.search("")}
        .onChange(of:query){_,value in if page==3{store.search(value)}}
    }
    var subtitle:String{["Записывай. Обрабатывай. Возвращайся к разговору.","Новые записи и незавершённые задания","Ход обработки и последние задания","Готовые разговоры с текстом и таймкодами","Папка, распознавание и названия"][page]}
    func nav(_ text:String,_ icon:String,_ index:Int,_ count:Int=0)->some View{
        Button{page=index}label:{HStack(spacing:12){Image(systemName:icon).frame(width:20);Text(text);Spacer();if count>0{Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)}}.padding(.horizontal,12).padding(.vertical,12).contentShape(Rectangle())}.buttonStyle(.plain).foregroundStyle(page==index ? accent:Color.secondary).background(page==index ? accent.opacity(0.12):Color.clear,in:RoundedRectangle(cornerRadius:10))
    }
    var home:some View{
        VStack(spacing:24){
            Button{pickFiles()}label:{
                VStack(spacing:16){Image(systemName:dropHovered ? "arrow.down.circle.fill":"arrow.down.doc").font(.system(size:44,weight:.light)).foregroundStyle(accent);Text("Перетащи записи сюда").font(.system(size:24,weight:.medium));Text("Аудио или видео · можно несколько файлов").foregroundStyle(.secondary);Text("или выбери файлы").foregroundStyle(accent);Text("Копии сохранятся в «Принадлежность уточнить»").font(.caption).foregroundStyle(.secondary)}.frame(maxWidth:.infinity,maxHeight:.infinity).frame(minHeight:230).background(dropHovered ? accent.opacity(0.09):surface.opacity(0.45),in:RoundedRectangle(cornerRadius:18)).overlay(RoundedRectangle(cornerRadius:18).strokeBorder(accent.opacity(dropHovered ? 0.8:0.3),style:StrokeStyle(lineWidth:1.5,dash:[8,6]))).contentShape(Rectangle())
            }.buttonStyle(.plain).onDrop(of:[UTType.fileURL.identifier],isTargeted:$dropHovered){providers in importDrop(providers);return true}
            HStack{if newFiles.isEmpty{Text("В папке нет новых записей").font(.callout).foregroundStyle(.secondary)}else{Button("Обработать новые · \(newFiles.count)"){store.send(["action":"enqueue","allNew":true]);page=2}.buttonStyle(.plain).foregroundStyle(accent).disabled(!store.ready)};Spacer();if !active.isEmpty{Button("В очереди: \(active.count) →"){page=2}.buttonStyle(.plain).foregroundStyle(accent)}}
            Spacer(minLength:8)
            VStack(spacing:20){
                Text(store.recording ? "Идёт запись":"Записать разговор").font(.title2.weight(.medium))
                if !store.recoveries.isEmpty || !store.stateNotice.isEmpty{Button("Есть данные для восстановления"){showReadiness=true}.font(.caption)}
                HStack(spacing:18){VStack(spacing:6){sourceButton("Компьютер","desktopcomputer","system");SystemAudioSourceMenu(store:store)};VStack(spacing:6){sourceButton("Микрофон","mic","mic");AudioRouteMenu(store:store,microphone:true)}}
                RecordingControl(store:store,accent:accent)
                Text(store.recordingStatus.isEmpty ? "Выбери один или оба источника":store.recordingStatus).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }.frame(maxWidth:.infinity).padding(.bottom,12)
        }
    }
    func sourceButton(_ title:String,_ icon:String,_ source:String)->some View{
        let enabled=store.mode==source || store.mode=="both"
        return Button{
            let system=store.mode=="system" || store.mode=="both";let mic=store.mode=="mic" || store.mode=="both"
            let nextSystem=source=="system" ? !system:system;let nextMic=source=="mic" ? !mic:mic
            store.mode=nextSystem && nextMic ? "both":nextSystem ? "system":nextMic ? "mic":"none"
        }label:{HStack(spacing:10){Image(systemName:icon).font(.title3);Text(title).fontWeight(.medium)}.frame(width:170,height:56).foregroundStyle(enabled ? accent:Color.secondary).background(enabled ? accent.opacity(0.15):surface,in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(enabled ? accent.opacity(0.6):Color.clear,lineWidth:1))}.buttonStyle(.plain).disabled(store.recording || store.startingRecording).accessibilityValue(enabled ? "Включён":"Выключен")
    }
    func importDrop(_ providers:[NSItemProvider]){
        Task{@MainActor in
            var urls:[URL]=[]
            for provider in providers{
                let url:URL?=await withCheckedContinuation{continuation in provider.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil){item,_ in
                    if let url=item as? URL{continuation.resume(returning:url)}else if let data=item as? Data{continuation.resume(returning:URL(dataRepresentation:data,relativeTo:nil))}else if let string=item as? String{continuation.resume(returning:URL(string:string))}else{continuation.resume(returning:nil)}
                }}
                if let url{urls.append(url)}
            }
            guard urls.count==providers.count,!urls.isEmpty else{store.error="Не удалось прочитать файлы. Выбери их кнопкой.";return}
            store.send(["action":"importPaths","paths":urls.map{$0.path}])
        }
    }
    var library:some View{
        VStack(spacing:16){
            HStack{Image(systemName:"magnifyingglass").foregroundStyle(.secondary);TextField("Найти разговор",text:$query).textFieldStyle(.plain);if !query.isEmpty{Button{query=""}label:{Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary)}.buttonStyle(.plain).help("Очистить поиск").accessibilityLabel("Очистить поиск")};Spacer();if page==2 && !newFiles.isEmpty{Button("Обработать новые"){store.send(["action":"enqueue","allNew":true])}.disabled(!store.ready)};if selectedReady.count==1,let row=selectedReady.first{Button(row.summaryReady==true ? "Открыть саммари":"Создать саммари"){if row.summaryReady==true{store.send(["action":"reader","id":row.id,"page":1])}else{store.send(["action":"summary","id":row.id])}}.disabled(store.jobs.contains{$0.kind=="summary" && $0.parentId==row.id && ["queued","working","converting"].contains($0.status)})};if !selected.isEmpty{Menu("Выбрано: \(selected.count)"){selectionMenu}}}.padding(12).background(surface,in:RoundedRectangle(cornerRadius:10))
            if page==2{HStack{if store.queuePaused{Text("Очередь на паузе").foregroundStyle(.secondary)};Spacer();Button(store.queuePaused ? "Продолжить очередь":"Пауза после текущего"){store.send(["action":"pauseQueue","paused":!store.queuePaused])}.buttonStyle(.plain).foregroundStyle(accent)}.font(.callout)}
            if page==3 && !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty{TranscriptSearchResults(store:store,query:query)}else if rows.isEmpty{Spacer();Image(systemName:page==3 ? "doc.text":"tray").font(.system(size:36)).foregroundStyle(.secondary);Text(query.isEmpty ? "Здесь пока пусто":"Ничего не найдено").font(.headline).foregroundStyle(.secondary);Spacer()}else{
                Table(rows,selection:$selected){
                    TableColumn("Разговор"){row in VStack(alignment:.leading,spacing:5){Button{if row.status=="done"{store.send(["action":"reader","id":row.id])}}label:{Text(row.title ?? row.name).fontWeight(.medium).lineLimit(1)}.buttonStyle(.plain).help(row.status=="done" ? "Открыть разговор":"Выбери действие в меню справа");Text(URL(fileURLWithPath:row.path).deletingLastPathComponent().lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)}.padding(.vertical,8)}.width(min:250,ideal:430)
                    TableColumn(""){row in
                        VStack(alignment:.leading,spacing:5){Text(dateText(row)).font(.callout.monospacedDigit());if !store.durationLabel(row).isEmpty{Text(store.durationLabel(row)).font(.caption.monospacedDigit())}}.foregroundStyle(.secondary)
                    }.width(155)
                    TableColumn("Статус"){row in HStack(spacing:7){Circle().fill(row.missing==true ? .gray:color(row.status)).frame(width:6,height:6);Text(row.label).foregroundStyle(.secondary);if row.summaryReady==true && row.status=="done"{Button{store.send(["action":"reader","id":row.id,"page":1])}label:{Image(systemName:"text.alignleft").font(.system(size:12)).foregroundStyle(accent)}.buttonStyle(.plain).help("Краткое содержание готово · открыть").accessibilityLabel("Открыть готовое краткое содержание")};if row.status=="working"{Text("\(Int(row.progress))%").font(.caption.monospacedDigit())}}}.width(150)
                    TableColumn(""){row in HStack{Spacer();Menu{rowMenu(row)}label:{Image(systemName:"ellipsis")}.menuStyle(.borderlessButton).frame(width:28).help("Действия с записью")}}.width(40)
                }.background(DateHeaderBridge(field:dateField,newest:dateNewestFirst,onToggle:{dateNewestFirst.toggle();dateOrder=[KeyPathComparator(\Call.dateKey,order:dateNewestFirst ? .reverse:.forward)]},onField:{dateField=$0}))
                .contextMenu(forSelectionType:String.self){ids in let targets=rows.filter{ids.contains($0.id)};if targets.count==1,let row=targets.first{rowMenu(row)}else{selectionMenu}} primaryAction:{ids in if let row=rows.first(where:{ids.contains($0.id)}),row.status=="done",row.resultMissing != true{store.send(["action":"reader","id":row.id])}}
                if let row=rows.first(where:{selected.contains($0.id)}),!row.message.isEmpty{Text(row.missing==true ? "Запись и папка результата не найдены. Можно убрать строку из списка.":row.message).font(.caption).foregroundStyle(.secondary).lineLimit(3).frame(maxWidth:.infinity,alignment:.leading)}
            }
        }
    }
    func dateText(_ row:Call)->String{
        guard let timestamp=(dateField=="created" ? row.created:row.modified) else{return "—"}
        return Date(timeIntervalSince1970:timestamp).formatted(.dateTime.day(.twoDigits).month(.twoDigits).year().hour().minute().locale(Locale(identifier:"ru_RU")))
    }
    var selectedRows:[Call]{rows.filter{selected.contains($0.id)}}
    var selectedReady:[Call]{selectedRows.filter{$0.status=="done" && $0.resultMissing != true && $0.kind != "summary" && $0.kind != "paragraphs" && $0.kind != "qa"}}
    @ViewBuilder var selectionMenu:some View{
        if selectedReady.count>=2{Button("Объединить разговоры…"){joinSelection=JoinSelection(parts:selectedReady.sorted{($0.created ?? $0.modified ?? 0)<($1.created ?? $1.modified ?? 0)})};Divider()}
        Button("Создать / пересоздать саммари (\(selectedReady.count))"){store.send(["action":"batch","operation":"summary","ids":selectedReady.map{$0.id}])}.disabled(selectedReady.isEmpty)
        let improveRows=selectedReady.filter{$0.kind != "improve"}
        Button("Повторить транскрибацию · large-v3 (\(improveRows.count))"){store.send(["action":"batch","operation":"improve","ids":improveRows.map{$0.id}])}.disabled(improveRows.isEmpty)
        if page != 3{Divider();Button("Обработать выбранные"){store.enqueue(selected)}.disabled(!store.ready);Button("Отменить обработку"){store.send(["action":"cancel","ids":Array(selected)])}}
        Divider()
        if !removable.isEmpty{Button("Убрать из списка — сохранить файлы (\(removable.count))"){store.removeExternal(removable);selected.subtract(removable)}}
        Button("Переместить выбранные в Корзину",role:.destructive){store.deleteCalls(selectedRows);selected=[]}.disabled(selectedRows.isEmpty || !selectedRows.allSatisfy({store.canDelete($0)}))
    }
    @ViewBuilder func rowMenu(_ row:Call)->some View{
        if row.kind=="qa" || row.kind=="merge" || row.kind=="paragraphs"{if row.status=="queued"{Button("Обработать следующим"){store.send(["action":"prioritize","id":row.id])}};if ["queued","working","converting","naming"].contains(row.status){Button("Отменить"){store.send(["action":"cancel","ids":[row.id]])}}else{Button("Убрать задание из списка"){store.removeExternal([row.id])}}}else{
        if row.kind != "improve" && row.status=="done" && row.resultMissing != true{
            Button("Улучшить транскрипт · large-v3"){store.send(["action":"improve","id":row.id]);page=2}.disabled(store.jobs.contains{ $0.kind=="improve" && $0.parentId==row.id && ["queued","working","converting","naming"].contains($0.status) })
            if let improved=store.jobs.last(where:{$0.parentId==row.id && $0.status=="done" && $0.kind=="improve" && $0.resultMissing != true}){Button("Читать улучшенную версию"){store.send(["action":"reader","id":improved.id])}}
            Divider()
        }
        if row.status=="waitingModel"{Button("Скачать модель…"){showReadiness=true}}
        if row.status=="done" && row.resultMissing != true{Button(row.summaryReady==true ? "Обновить саммари":"Создать саммари"){store.send(["action":"summary","id":row.id])}.disabled(store.jobs.contains{$0.kind=="summary" && $0.parentId==row.id && ["queued","working","converting"].contains($0.status)});Divider();Button("Читать транскрипт"){store.send(["action":"reader","id":row.id])};Button("Показать результат в Finder"){store.send(["action":"open","id":row.id])}}
        if row.status=="queued"{Button("Обработать следующим"){store.send(["action":"prioritize","id":row.id])}}
        if ["queued","working","converting","naming","waitingModel"].contains(row.status){Button("Отменить обработку"){store.send(["action":"cancel","ids":[row.id]])}}else if row.status != "done" && row.missing != true{Button("Обработать"){if row.kind=="improve",let parent=row.parentId{store.send(["action":"improve","id":parent])}else{store.enqueue([row.id])}}.disabled(!store.ready)}
        if store.canRemove(row){Button("Убрать из списка — сохранить файлы"){store.removeExternal([row.id])}}
        if row.missing != true && ((row.kind != "improve" && row.kind != "summary") || (row.kind=="improve" && row.status=="done")){Button("Показать запись в Finder"){NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:row.path)])};Divider();Button("Переместить в Корзину",role:.destructive){store.deleteCall(row)}.disabled(["queued","working","converting","naming"].contains(row.status))}
    }
    }
    var settings:some View{
        ScrollView{
            VStack(alignment:.leading,spacing:28){
                VStack(alignment:.leading,spacing:14){Text("Папка созвонов").font(.headline);Text(store.folder).font(.callout).foregroundStyle(.secondary).textSelection(.enabled);HStack{Button("Изменить…"){store.chooseFolder()};Button("Открыть в Finder"){NSWorkspace.shared.open(URL(fileURLWithPath:store.folder))}}}.padding(22).frame(maxWidth:.infinity,alignment:.leading).background(surface,in:RoundedRectangle(cornerRadius:12))
                VStack(alignment:.leading,spacing:18){
                    HStack{Text("Локальные модели").font(.headline);Spacer();Button{store.send(["action":"refreshModels"])}label:{Image(systemName:"arrow.clockwise")}.buttonStyle(.plain).help("Найти встроенные и пользовательские модели")}
                    HStack{Picker("Транскрибация",selection:Binding(get:{store.speechModel},set:{set("speechModel",$0)})){ForEach(store.models.speech){model in Text(model.name).tag(model.path)};if !store.models.speech.contains(where:{$0.path==store.speechModel}){Text("Модель не найдена").tag(store.speechModel)}};Button("Выбрать файл…"){chooseModel(false)}}
                    HStack{Picker("LLM для названий",selection:Binding(get:{store.titleModel},set:{set("titleModel",$0)})){ForEach(store.models.llm){model in Text(model.name).tag(model.path)};if !store.models.llm.contains(where:{$0.path==store.titleModel}){Text("Модель не найдена").tag(store.titleModel)}};Button("Выбрать файл…"){chooseModel(true)}}
                    Picker("Формат диалога LLM",selection:Binding(get:{store.titleTemplate},set:{set("titleTemplate",$0)})){Text("ChatML · Qwen").tag("chatml");Text("Llama 3").tag("llama3");Text("Gemma").tag("gemma")}
                    DisclosureGroup("Какие модели поддерживаются"){
                        VStack(alignment:.leading,spacing:12){
                            Text("Распознавание · whisper.cpp 1.9.5-dev").font(.callout.weight(.semibold))
                            Text("Whisper tiny, base, small, medium, large-v1/v2/v3 и large-v3-turbo в формате GGML .bin; поддерживаются квантованные варианты. Для русского выбирай многоязычные модели, без .en. Проверена на этом Mac: large-v3-turbo.")
                            Text("Названия · встроенный llama.cpp").font(.callout.weight(.semibold))
                            Text("Проверена: Qwen3.5-4B Q4_K_M, архитектура qwen35. В установленном движке есть Qwen2/3/3.5, Llama и Gemma 1/2/3. Наличие архитектуры не гарантирует работу каждого GGUF: важны квантование, версия файла и шаблон диалога. Остальные модели пока не проверены.")
                            Text("ChatML — Qwen; Llama 3 — модели Llama 3; Gemma — модели Gemma. Для других семейств и шаблонов интеграция не готова. Только текст: изображения в LLM не передаются.")
                            Text("Не подключаются напрямую: Core ML / WhisperKit, MLX, Safetensors, PyTorch .pt, Ollama и Parakeet. Расширение .bin или .gguf само по себе не означает совместимость.")
                            Text("Память: размер файла — только веса. Нужен запас на контекст, рабочие буферы и macOS. Whisper и LLM запускаются последовательно. Модель для названий не исправляет качество транскрибации.")
                        }.font(.caption).foregroundStyle(.secondary).padding(.top,10)
                    }
                }.padding(22).background(surface,in:RoundedRectangle(cornerRadius:12))
                VStack(alignment:.leading,spacing:18){ModelDownloadsView(store:store);Button("Проверка и восстановление…"){showReadiness=true};Button("Начальная настройка и разрешения…"){showSetup=true};Button("Скопировать диагностику"){store.copyDiagnostics()}}.padding(22).background(surface,in:RoundedRectangle(cornerRadius:12))
                VStack(alignment:.leading,spacing:18){Text("Распознавание").font(.headline);Picker("Язык",selection:Binding(get:{store.language},set:{set("language",$0)})){Text("Русский").tag("ru");Text("Английский").tag("en");Text("Определять автоматически").tag("auto")};Picker("Режим",selection:Binding(get:{store.quality},set:{set("quality",$0)})){Text("Точный").tag("precise");Text("Быстрый").tag("fast")};Toggle("Пропускать длинные паузы",isOn:Binding(get:{store.vad},set:{set("vad",$0)}));Toggle("Названия по содержанию",isOn:Binding(get:{store.naming},set:{store.send(["action":"naming","enabled":$0])}));Text("Имена и термины").font(.callout);TextField("Например: Телемост, Seedance, РАНХиГС",text:Binding(get:{store.glossary},set:{set("glossary",String($0.prefix(600)))})).textFieldStyle(.roundedBorder);Text("Сохраняется автоматически. Применяется к новым заданиям.").font(.caption).foregroundStyle(.secondary)}.padding(22).background(surface,in:RoundedRectangle(cornerRadius:12))
                Text("Распознавание, саммари и чат работают локально. Для скачивания моделей нужен интернет.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth:660,alignment:.leading)
        }
    }
    func chooseModel(_ llm:Bool){let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false;panel.allowedContentTypes=[UTType(filenameExtension:llm ? "gguf":"bin") ?? .data];panel.prompt="Подключить модель";if panel.runModal() == .OK,let url=panel.url{set(llm ? "titleModel":"speechModel",url.path)}}
    func set(_ key:String,_ value:Any){store.send(["action":"settings",key:value])}
    func pickFiles(){let panel=NSOpenPanel();panel.allowsMultipleSelection=true;panel.canChooseDirectories=false;panel.allowedContentTypes=[.audio,.movie];panel.prompt="Транскрибировать";if panel.runModal() == .OK{store.send(["action":"importPaths","paths":panel.urls.map{$0.path}])}}
    func color(_ status:String)->Color{switch status{case "done":return .green;case "error":return .orange;case "working","naming","converting":return accent;case "queued":return .purple;default:return .gray}}
}

func openTranscriptTXT(_ path:String){
    let config=NSWorkspace.OpenConfiguration()
    NSWorkspace.shared.open([URL(fileURLWithPath:path)],withApplicationAt:URL(fileURLWithPath:"/System/Applications/TextEdit.app"),configuration:config){_,error in
        if let error{DispatchQueue.main.async{let alert=NSAlert();alert.messageText="Не удалось открыть TXT";alert.informativeText=error.localizedDescription;alert.runModal()}}
    }
}
struct TranscriptWebView:NSViewRepresentable {
    var path:String
    class Coordinator:NSObject,WKNavigationDelegate{
        func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void){
            if let url=action.request.url,url.pathExtension.lowercased()=="txt"{
                decisionHandler(.cancel);openTranscriptTXT(url.path);return
            }
            if let url=action.request.url,!url.isFileURL,url.scheme != "about"{decisionHandler(.cancel);return}
            decisionHandler(.allow)
        }
    }
    func makeCoordinator()->Coordinator{Coordinator()}
    func makeNSView(context:Context)->WKWebView{
        let config=WKWebViewConfiguration();config.mediaTypesRequiringUserActionForPlayback=[];config.preferences.javaScriptCanOpenWindowsAutomatically=false
        let web=WKWebView(frame:.zero,configuration:config);web.navigationDelegate=context.coordinator
        web.loadFileURL(URL(fileURLWithPath:path),allowingReadAccessTo:URL(fileURLWithPath:path).deletingLastPathComponent())
        return web
    }
    func updateNSView(_ web:WKWebView,context:Context){if web.url == nil && !web.isLoading{web.loadFileURL(URL(fileURLWithPath:path),allowingReadAccessTo:URL(fileURLWithPath:path).deletingLastPathComponent())}}
    static func dismantleNSView(_ web:WKWebView,coordinator:Coordinator){web.evaluateJavaScript("document.querySelectorAll('audio').forEach(a=>a.pause())");web.stopLoading()}
}
struct ReaderToolbar:View {
    let reader:Reader;var close:()->Void
    var body:some View{
        HStack{Text("Транскрипт").font(.headline);Spacer();Button("Открыть TXT"){openTranscriptTXT(reader.txt)};Button("Экспорт TXT"){export()};Button("Закрыть"){close()}.keyboardShortcut(.cancelAction)}.padding(16).frame(maxWidth:.infinity)
    }
    func export(){let panel=NSSavePanel();panel.nameFieldStringValue=URL(fileURLWithPath:reader.txt).lastPathComponent;if panel.runModal() == .OK,let target=panel.url{do{let data=try Data(contentsOf:URL(fileURLWithPath:reader.txt));try data.write(to:target,options:.atomic)}catch{let alert=NSAlert();alert.messageText="Не удалось сохранить TXT";alert.informativeText=error.localizedDescription;alert.runModal()}}}
}
struct RecognitionSettings:View {
    @ObservedObject var store:Store;@Environment(\.dismiss)var dismiss
    @State var language="ru";@State var quality="precise";@State var glossary="";@State var vad=true
    var body:some View{
        VStack(alignment:.leading,spacing:18){Text("Распознавание речи").font(.title2.bold());Text("Whisper large-v3-turbo · локально, с ускорением Metal").foregroundStyle(.secondary)
            Picker("Язык записи",selection:$language){Text("Русский").tag("ru");Text("Английский").tag("en");Text("Определять автоматически").tag("auto")}
            Picker("Режим",selection:$quality){Text("Точный — несколько вариантов декодирования").tag("precise");Text("Быстрый — один вариант").tag("fast")}
            Toggle("Определять речь и пропускать длинные паузы",isOn:$vad)
            Text("Имена и термины").font(.headline)
            TextEditor(text:$glossary).font(.body).frame(height:110).padding(6).overlay(RoundedRectangle(cornerRadius:7).stroke(.quaternary))
            Text("Например: Киностудия Москва, Телемост, Seedance, Higgsfield, РАНХиГС. До 600 символов. Это подсказка распознаванию, а не инструкция модели.").font(.caption).foregroundStyle(.secondary)
            Text("Таймкоды сохраняются всегда. Настройки применятся к новым заданиям. Qwen создаёт только название и не редактирует распознанную речь.").font(.callout).foregroundStyle(.secondary)
            HStack{Spacer();Button("Отмена"){dismiss()}.keyboardShortcut(.cancelAction);Button("Сохранить"){store.send(["action":"settings","language":language,"quality":quality,"glossary":String(glossary.prefix(600)),"vad":vad]);dismiss()}.buttonStyle(.borderedProminent)}
        }.padding(28).frame(width:650).onAppear{language=store.language;quality=store.quality;glossary=store.glossary;vad=store.vad}
    }
}

@MainActor final class Delegate:NSObject,NSApplicationDelegate{
    var store:Store?
    var pendingFiles:[URL]=[];var pendingLinks:[URL]=[]
    var fileToolsWindows:[UUID:FileToolsWindowController]=[:]
    func attachStore(_ value:Store){store=value;if !pendingFiles.isEmpty{let urls=pendingFiles;pendingFiles=[];value.enqueueFiles(urls)};for url in pendingLinks{value.send(["action":"openLink","url":url.absoluteString])};pendingLinks=[]}
    func applicationDidFinishLaunching(_ notification:Notification){NSApp.servicesProvider=self;NSUpdateDynamicServices()}
    func application(_ application:NSApplication,open urls:[URL]){let files=urls.filter{$0.isFileURL};if !files.isEmpty{receiveFiles(files)};for url in urls where url.scheme=="calls"{if let store{store.send(["action":"openLink","url":url.absoluteString])}else{pendingLinks.append(url)}}}
    func receiveFiles(_ urls:[URL]){if let store{store.enqueueFiles(urls)}else{pendingFiles.append(contentsOf:urls)}}
    @objc func transcribeFiles(_ pasteboard:NSPasteboard,userData:String?,error:AutoreleasingUnsafeMutablePointer<NSString?>){
        var urls=(pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL]) ?? []
        if urls.isEmpty,let paths=pasteboard.propertyList(forType:NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String]{urls=paths.map{URL(fileURLWithPath:$0)}}
        let media:Set<String>=["wav","mp3","m4a","mp4","webm","mkv","mov","aac","ogg","flac","aiff","opus"];guard !urls.isEmpty,urls.allSatisfy({media.contains($0.pathExtension.lowercased())}) else{error.pointee="Выбери только аудио- или видеофайлы. Для остальных есть «Сжать или конвертировать…».";return}
        receiveFiles(urls)
    }
    @objc func convertFiles(_ pasteboard:NSPasteboard,userData:String?,error:AutoreleasingUnsafeMutablePointer<NSString?>){
        var urls=(pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL]) ?? []
        if urls.isEmpty,let paths=pasteboard.propertyList(forType:NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String]{urls=paths.map{URL(fileURLWithPath:$0)}}
        urls=urls.filter{(try? $0.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile)==true}
        guard !urls.isEmpty else{error.pointee="Выбери один или несколько файлов, не папку.";return}
        let id=UUID();let controller=FileToolsWindowController(urls:urls);controller.onClose={[weak self] in self?.fileToolsWindows.removeValue(forKey:id)};fileToolsWindows[id]=controller
        controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{
        for controller in fileToolsWindows.values{controller.model.cancel()}
        guard let s=store else{return .terminateNow}
        if s.recording || s.startingRecording{Task{@MainActor in while s.startingRecording{try? await Task.sleep(for:.milliseconds(100))};if s.recording{await s.finishRecording()};s.shutdown();NSApp.reply(toApplicationShouldTerminate:true)};return .terminateLater}
        s.shutdown();return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
}
struct MenuBarControls:View{
    @ObservedObject var store:Store
    @Environment(\.openWindow)var openWindow
    @State var loginEnabled=SMAppService.mainApp.status == .enabled
    var active:Int{store.jobs.filter{["queued","working","converting","naming"].contains($0.status)}.count}
    var body:some View{
        Button("Открыть Rehear"){showApp()}.keyboardShortcut("o")
        if store.recording{Text("● Идёт запись")}
        if active>0{Text("В обработке и очереди: \(active)")}
        Divider()
        Button("Обработать новые звонки"){store.send(["action":"enqueue","allNew":true])}.disabled(!store.ready)
        if store.recording{
            Button("Остановить и сохранить запись"){store.record()}
        }else{
            Menu("Записать звук"){
                Button("Компьютер + микрофон"){startRecord("both")}
                Button("Только компьютер"){startRecord("system")}
                Button("Только микрофон"){startRecord("mic")}
            }.disabled(store.startingRecording)
        }
        Button("Открыть папку звонков"){NSWorkspace.shared.open(URL(fileURLWithPath:store.folder))}.disabled(store.folder.isEmpty)
        Divider()
        Toggle("Запускать при входе в macOS",isOn:Binding(get:{loginEnabled},set:{enabled in
            do{if enabled{try SMAppService.mainApp.register()}else{try SMAppService.mainApp.unregister()};loginEnabled=SMAppService.mainApp.status == .enabled
                if enabled && !loginEnabled{store.error="Подтверди запуск Rehear в настройках macOS → Основные → Объекты входа.";showApp()}
            }catch{store.error=error.localizedDescription;showApp()}
        }))
        Divider()
        Button("Завершить Rehear"){NSApp.terminate(nil)}.keyboardShortcut("q")
    }
    func showApp(){openWindow(id:"main");NSApp.activate(ignoringOtherApps:true)}
    func startRecord(_ mode:String){store.mode=mode;store.record()}
}
@main struct CallsApp:App{
    @NSApplicationDelegateAdaptor(Delegate.self)var delegate
    @StateObject var store=Store()
    var body:some Scene{
        Window("Rehear",id:"main"){
            ContentView().environmentObject(store).onAppear{delegate.attachStore(store);NSApp.setActivationPolicy(.regular);NSApp.activate(ignoringOtherApps:true)}
        }.defaultSize(width:1160,height:790).commands{
            CommandGroup(replacing:.newItem){Button("Обработать новые"){store.send(["action":"enqueue","allNew":true])}.keyboardShortcut("n",modifiers:[.command,.shift])}
        }
        MenuBarExtra{
            MenuBarControls(store:store)
        }label:{Image(systemName:store.recording ? "record.circle.fill":"waveform")}
        .menuBarExtraStyle(.menu)
    }
}

// Attach two controls to the actual date-column header, following its native layout.
struct DateHeaderBridge:NSViewRepresentable {
    var field:String;var newest:Bool;var onToggle:()->Void;var onField:(String)->Void
    func makeNSView(context:Context)->DateHeaderAnchor{DateHeaderAnchor()}
    func updateNSView(_ view:DateHeaderAnchor,context:Context){view.field=field;view.newest=newest;view.onToggle=onToggle;view.onField=onField;view.attach()}
}
final class DateHeaderAnchor:NSView {
    var field="modified";var newest=true;var onToggle:(()->Void)?;var onField:((String)->Void)?
    private var timer:Timer?
    private let controls=DateColumnControls(frame:.zero)
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();timer?.invalidate();if window != nil{timer=Timer.scheduledTimer(withTimeInterval:0.2,repeats:true){[weak self] _ in self?.attach()};attach()}else{controls.removeFromSuperview()}}
    deinit{timer?.invalidate()}
    func attach(){
        guard window != nil else{return}
        func find(_ view:NSView)->NSTableView?{if let table=view as? NSTableView{return table};for child in view.subviews{if let table=find(child){return table}};return nil}
        var parent=superview
        var found:NSTableView?
        while let node=parent{if let table=find(node){found=table;break};parent=node.superview}
        guard let table=found,table.tableColumns.count>1,let header=table.headerView else{return}
        if controls.superview !== header{controls.removeFromSuperview();header.addSubview(controls)}
        table.tableColumns[1].headerCell.stringValue=""
        controls.frame=header.headerRect(ofColumn:1).insetBy(dx:1,dy:0)
        controls.configure(field:field,newest:newest)
        controls.onToggle=onToggle;controls.onField=onField
    }
}
final class DateColumnControls:NSView {
    override var allowsVibrancy:Bool{false}
    override var isOpaque:Bool{false}
    var onToggle:(()->Void)?;var onField:((String)->Void)?;var field="modified";var newest=true
    func configure(field:String,newest:Bool){self.field=field;self.newest=newest;needsDisplay=true}
    override func draw(_ dirtyRect:NSRect){
        let text=(field=="created" ? "Создание":"Изменение")+(newest ? " ↓":" ↑")
        let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:12,weight:.semibold),.foregroundColor:NSColor.labelColor]
        let height=(text as NSString).size(withAttributes:attrs).height
        (text as NSString).draw(at:NSPoint(x:8,y:(bounds.height-height)/2),withAttributes:attrs)
        let path=NSBezierPath();let x=bounds.width-13,y=bounds.midY
        path.move(to:NSPoint(x:x-4,y:y+2));path.line(to:NSPoint(x:x,y:y-2));path.line(to:NSPoint(x:x+4,y:y+2));path.lineWidth=1.3;NSColor.secondaryLabelColor.setStroke();path.stroke()
    }
    override func mouseDown(with event:NSEvent){let point=convert(event.locationInWindow,from:nil);if point.x>=bounds.width-26{showMenu()}else{onToggle?()}}
    func showMenu(){let menu=NSMenu();for (label,value) in [("Дата создания","created"),("Дата изменения","modified")]{let item=NSMenuItem(title:label,action:#selector(choose(_:)),keyEquivalent:"");item.target=self;item.representedObject=value;item.state=field==value ? .on:.off;menu.addItem(item)};menu.popUp(positioning:nil,at:NSPoint(x:bounds.width-24,y:0),in:self)}
    @objc func choose(_ sender:NSMenuItem){if let value=sender.representedObject as? String{onField?(value)}}
}

struct AudioRouteMenu:View{
    @ObservedObject var store:Store;@ObservedObject var routes:AudioRoutes;let microphone:Bool
    init(store:Store,microphone:Bool){self.store=store;self.routes=store.audioRoutes;self.microphone=microphone}
    var body:some View{
        Menu{
            if microphone{
                Button((routes.microphone.isEmpty ? "✓ ":"")+"Автоматически · микрофон macOS"){routes.microphone="";store.recorder?.selectMicrophone("")}
                Divider()
                ForEach(routes.inputs){device in Button((routes.microphone==device.uid ? "✓ ":"")+device.name){routes.microphone=device.uid;store.recorder?.selectMicrophone(device.uid)}}
            }else{
                Text("Выход звука macOS · запись всего звука")
                ForEach(routes.outputs){device in Button((routes.outputID==device.id ? "✓ ":"")+device.name){do{try routes.chooseOutput(device.id)}catch{store.error=error.localizedDescription}}}
            }
        }label:{Text(microphone ? ((store.recording && store.mode != "system") ? routes.actualMicrophone:routes.microphoneName):routes.outputName).font(.caption).lineLimit(1).truncationMode(.middle).frame(width:170)}.menuStyle(.borderlessButton).frame(width:170).help(microphone ? "Выбрать микрофон · можно во время записи":"Выбрать выход звука macOS · записывается весь системный звук")
    }
}
struct RecordingControl:View{
    @ObservedObject var store:Store;let accent:Color
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body:some View{
        VStack(spacing:10){
            TimelineView(.animation(minimumInterval:1.0/30,paused:!store.recording || reduceMotion)){context in
                let phase=context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy:2.4)/2.4
                ZStack{
                    if store.recording{ForEach(0..<2){i in let p=(phase+Double(i)*0.5).truncatingRemainder(dividingBy:1);Circle().stroke(Color.red.opacity(reduceMotion ? 0.2:(1-p)*0.3),lineWidth:1.5).frame(width:108,height:108).scaleEffect(reduceMotion ? 1.15:1+p*0.38)}}
                    Button{store.record()}label:{Image(systemName:store.recording ? "stop.fill":"mic.fill").font(.system(size:38,weight:.medium)).foregroundStyle(.white).frame(width:108,height:108).background(store.recording ? Color.red:accent,in:Circle()).overlay(Circle().stroke(Color.white.opacity(0.12),lineWidth:1))}.buttonStyle(.plain).disabled(store.startingRecording || store.finishingRecording || (!store.recording && store.mode=="none")).help(store.recording ? "Остановить и сохранить":"Начать запись").accessibilityLabel(store.recording ? "Остановить и сохранить":"Начать запись")
                }.frame(width:148,height:148)
            }
            if let start=store.recordingStarted{TimelineView(.periodic(from:start,by:1)){context in let seconds=max(0,Int(context.date.timeIntervalSince(start)));Text(String(format:"%02d:%02d:%02d",seconds/3600,(seconds/60)%60,seconds%60)).font(.system(.title3,design:.monospaced)).foregroundStyle(.secondary).accessibilityLabel("Длительность записи")}}
        }
    }
}

func compactDuration(_ seconds:Double)->String{
    guard seconds.isFinite,seconds>0 else{return "—"}
    let n=max(1,Int(seconds.rounded()))
    if n<60{return "\(n) сек"}
    if n<3600{return "\(n/60) мин"}
    return n%3600<60 ? "\(n/3600) ч":"\(n/3600) ч \(n%3600/60) мин"
}
