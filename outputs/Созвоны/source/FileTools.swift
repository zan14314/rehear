import SwiftUI
import AppKit
import Darwin

func fileKind(_ url:URL)->String{
    let ext=url.pathExtension.lowercased()
    if ["png","jpg","jpeg","heic","heif","tif","tiff","bmp","gif","webp"].contains(ext){return "image"}
    if ["mp4","mov","m4v","webm","mkv","avi","mpeg","mpg"].contains(ext){return "video"}
    if ["txt","md","markdown","rtf","docx","doc","log","csv","tsv","json","yaml","yml","xml","srt","vtt","py","js","ts","swift","css","ini","html"].contains(ext){return "text"}
    return "archive"
}
struct FileToolResult:Identifiable{
    var id=UUID();var name:String;var output:String;var originalSize:Int64;var size:Int64;var details:String;var error:String
}
func prettyBytes(_ count:Int64)->String{ByteCountFormatter.string(fromByteCount:count,countStyle:.file)}
@MainActor final class FileToolsModel:ObservableObject{
    let urls:[URL]
    @Published var imageFormat="jpeg";@Published var imageQuality=0.8;@Published var maxSide=0;@Published var imageLimited=false;@Published var imageMB=1.0
    @Published var videoFormat="mp4";@Published var videoQuality=0.8;@Published var height=1080;@Published var videoLimited=false;@Published var videoMB=25.0
    @Published var fontSize=12.0;@Published var archiveOnly=false
    @Published var busy=false;@Published var status="";@Published var results:[FileToolResult]=[]
    var activeProcess:Process?;var cancelled=false
    var kinds:Set<String>{Set(urls.map(fileKind))}
    init(urls:[URL]){self.urls=urls}
    func cancel(){cancelled=true;if let process=activeProcess,process.isRunning{if kill(-process.processIdentifier,SIGTERM) != 0{process.terminate()}}}
    func create(){
        guard !busy else{return};busy=true;cancelled=false;results=[]
        let options:[String:Any]=["imageFormat":imageFormat,"imageQuality":imageQuality,"maxSide":maxSide,"imageTarget":imageLimited ? imageMB:0,"videoFormat":videoFormat,"videoQuality":videoQuality,"height":height,"videoTarget":videoLimited ? videoMB:0,"fontSize":fontSize,"archiveOnly":archiveOnly]
        Task{
            defer{busy=false;activeProcess=nil;status=cancelled ? "Отменено. Оригиналы сохранены.":"Готово: \(results.filter{$0.error.isEmpty}.count) из \(urls.count)"}
            for (index,url) in urls.enumerated(){
                if cancelled{break};status="\(index+1) из \(urls.count) · \(url.lastPathComponent)"
                let scratch=FileManager.default.temporaryDirectory.appendingPathComponent("CallsConvert-"+UUID().uuidString)
                do{
                    try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true)
                    defer{try? FileManager.default.removeItem(at:scratch)}
                    let kind=(options["archiveOnly"] as? Bool)==true ? "archive":fileKind(url)
                    var request:[String:Any]=["source":url.path,"scratch":scratch.path,"kind":kind,"fontSize":options["fontSize"]!]
                    switch kind{
                    case "image":request.merge(["format":options["imageFormat"]!,"quality":options["imageQuality"]!,"maxSide":options["maxSide"]!,"targetMB":options["imageTarget"]!]){_,new in new}
                    case "video":request.merge(["format":options["videoFormat"]!,"quality":options["videoQuality"]!,"height":options["height"]!,"targetMB":options["videoTarget"]!]){_,new in new}
                    case "text":request["format"]="pdf"
                    default:request["format"]="zip"
                    }
                    let process=Process();let input=Pipe();let output=Pipe()
                    process.executableURL=Bundle.main.resourceURL!.appendingPathComponent("FileConverter");process.standardInput=input;process.standardOutput=output;process.standardError=FileHandle.nullDevice
                    let originalSize=Int64((try url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)
                    let originalModification=try url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate
                    try process.run();activeProcess=process
                    try input.fileHandleForWriting.write(contentsOf:JSONSerialization.data(withJSONObject:request));try input.fileHandleForWriting.close()
                    let data:Data=await withCheckedContinuation{continuation in DispatchQueue.global(qos:.userInitiated).async{process.waitUntilExit();continuation.resume(returning:output.fileHandleForReading.readDataToEndOfFile())}}
                    activeProcess=nil;if cancelled{break}
                    guard let result=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw NSError(domain:"Convert",code:1,userInfo:[NSLocalizedDescriptionKey:"Не удалось прочитать результат"])}
                    guard result["ok"] as? Bool==true,let path=result["file"] as? String else{throw NSError(domain:"Convert",code:1,userInfo:[NSLocalizedDescriptionKey:result["error"] as? String ?? "Обработка не завершилась"])}
                    let converted=URL(fileURLWithPath:path)
                    guard converted.deletingLastPathComponent().standardizedFileURL==scratch.standardizedFileURL else{throw NSError(domain:"Convert",code:1,userInfo:[NSLocalizedDescriptionKey:"Некорректный путь результата"])}
                    guard originalModification==(try url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) else{throw NSError(domain:"Convert",code:1,userInfo:[NSLocalizedDescriptionKey:"Исходник изменился во время обработки. Повтори после сохранения."])}
                    let stem=url.deletingPathExtension().lastPathComponent+(kind=="text" ? " — документ":kind=="archive" ? " — архив":" — обработано")
                    var destination=url.deletingLastPathComponent().appendingPathComponent(stem+"."+converted.pathExtension);var n=2
                    while FileManager.default.fileExists(atPath:destination.path){destination=url.deletingLastPathComponent().appendingPathComponent(stem+" (\(n))."+converted.pathExtension);n+=1}
                    try FileManager.default.moveItem(at:converted,to:destination)
                    results.append(FileToolResult(name:url.lastPathComponent,output:destination.path,originalSize:originalSize,size:(result["size"] as? NSNumber)?.int64Value ?? 0,details:result["details"] as? String ?? "",error:""))
                }catch{
                    try? FileManager.default.removeItem(at:scratch)
                    if !cancelled{results.append(FileToolResult(name:url.lastPathComponent,output:"",originalSize:0,size:0,details:"",error:error.localizedDescription))}
                }
            }
        }
    }
}
struct FileToolsView:View{
    @ObservedObject var model:FileToolsModel
    var close:()->Void
    var body:some View{
        VStack(alignment:.leading,spacing:16){
            HStack{VStack(alignment:.leading,spacing:4){Text("Сжать или конвертировать").font(.title2.bold());Text("\(model.urls.count) файлов · результаты рядом с оригиналами").foregroundStyle(.secondary)};Spacer();Image(systemName:"arrow.triangle.2.circlepath").font(.title).foregroundStyle(.blue)}
            ScrollView{
                VStack(alignment:.leading,spacing:16){
                    ForEach(model.urls,id:\.path){url in HStack{Image(systemName:icon(fileKind(url))).foregroundStyle(.secondary);Text(url.lastPathComponent).lineLimit(1);Spacer();Text(prettyBytes(Int64((try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0))).foregroundStyle(.secondary)}.font(.callout)}
                    Toggle("Упаковать в ZIP без изменения содержимого",isOn:$model.archiveOnly)
                    if !model.archiveOnly{
                        if model.kinds.contains("image"){
                            GroupBox("Изображения"){
                                VStack(alignment:.leading,spacing:12){
                                    Picker("Формат",selection:$model.imageFormat){Text("JPEG").tag("jpeg");Text("PNG").tag("png");Text("HEIC").tag("heic")}
                                    HStack{Text("Качество: \(Int(model.imageQuality*100))%");Slider(value:$model.imageQuality,in:0.1...1)}.disabled(model.imageFormat=="png")
                                    Picker("Длинная сторона",selection:$model.maxSide){Text("Исходный размер").tag(0);Text("4096 px").tag(4096);Text("2048 px").tag(2048);Text("1280 px").tag(1280);Text("800 px").tag(800)}
                                    HStack{Toggle("Не больше",isOn:$model.imageLimited);TextField("МБ",value:$model.imageMB,format:.number).frame(width:80).disabled(!model.imageLimited);Text("МБ на изображение")}
                                    Text("Для лимита размер и качество могут снизиться. В JPEG и HEIC прозрачность заменяется белым фоном. GIF сохраняется как одна картинка.").font(.caption).foregroundStyle(.secondary)
                                }.padding(8)
                            }
                        }
                        if model.kinds.contains("video"){
                            GroupBox("Видео"){
                                VStack(alignment:.leading,spacing:12){
                                    Picker("Формат",selection:$model.videoFormat){Text("MP4 · H.264").tag("mp4");Text("MOV · H.264").tag("mov");Text("WebM · VP9").tag("webm")}
                                    Picker("Разрешение",selection:$model.height){Text("Исходное").tag(0);Text("До 1080p").tag(1080);Text("До 720p").tag(720);Text("До 480p").tag(480)}
                                    HStack{Text("Качество: \(Int(model.videoQuality*100))%");Slider(value:$model.videoQuality,in:0.1...1)}.disabled(model.videoLimited)
                                    HStack{Toggle("Не больше",isOn:$model.videoLimited);TextField("МБ",value:$model.videoMB,format:.number).frame(width:80).disabled(!model.videoLimited);Text("МБ на видео")}
                                    Text("С лимитом используется два прохода. Маленький размер снижает качество; длительность сохраняется. Сохраняются одна видеодорожка и первая аудиодорожка. HDR не поддерживается.").font(.caption).foregroundStyle(.secondary)
                                }.padding(8)
                            }
                        }
                        if model.kinds.contains("text"){
                            GroupBox("Текст → PDF"){
                                VStack(alignment:.leading,spacing:10){Text("Страницы A4, поля и нумерация");HStack{Text("Размер шрифта для простого текста: \(Int(model.fontSize))");Slider(value:$model.fontSize,in:10...18,step:1)};Text("TXT и Markdown сохраняются как текст. Для сложных DOCX оформление может отличаться от Word.").font(.caption).foregroundStyle(.secondary)}.padding(8)
                            }
                        }
                        if model.kinds.contains("archive"){Text("Остальные файлы будут упакованы в отдельные ZIP. Уже сжатые форматы могут почти не уменьшиться.").font(.callout).foregroundStyle(.secondary)}
                    }
                    if !model.results.isEmpty{
                        Divider();ForEach(model.results){result in
                            VStack(alignment:.leading,spacing:5){
                                HStack{Text(result.name).font(.headline).lineLimit(1);Spacer();if result.error.isEmpty{Button("Открыть"){NSWorkspace.shared.open(URL(fileURLWithPath:result.output))};Button{NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:result.output)])}label:{Image(systemName:"folder")}}}
                                if result.error.isEmpty{Text("\(prettyBytes(result.originalSize)) → \(prettyBytes(result.size)) · \(result.details)").font(.callout).foregroundStyle(.secondary)}else{Text(result.error).font(.callout).foregroundStyle(.red).textSelection(.enabled)}
                            }.padding(10).background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:8))
                        }
                    }
                }.disabled(model.busy)
            }
            if model.busy{ProgressView().progressViewStyle(.linear)}
            Text(model.status.isEmpty ? "Оригиналы сохраняются. Сжатие с потерями может снизить качество.":model.status).font(.caption).foregroundStyle(.secondary)
            HStack{Button("Закрыть"){close()};Spacer();if model.busy{Button("Отменить"){model.cancel()}}else{Button("Создать файлы"){model.create()}.buttonStyle(.borderedProminent).disabled(model.imageLimited && (!model.imageMB.isFinite || model.imageMB<=0 || model.imageMB>100000) || model.videoLimited && (!model.videoMB.isFinite || model.videoMB<=0 || model.videoMB>100000))}}
        }.padding(24).frame(minWidth:700,minHeight:600)
    }
    func icon(_ kind:String)->String{["image":"photo","video":"film","text":"doc.text","archive":"doc.zipper"][kind] ?? "doc"}
}
@MainActor final class FileToolsWindowController:NSWindowController,NSWindowDelegate{
    let model:FileToolsModel;var onClose:(()->Void)?
    init(urls:[URL]){
        model=FileToolsModel(urls:urls)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:760),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="Сжать или конвертировать";window.isReleasedWhenClosed=false;window.minSize=NSSize(width:720,height:620);window.tabbingMode = .disallowed
        super.init(window:window)
        window.contentView=NSHostingView(rootView:FileToolsView(model:model,close:{[weak window] in window?.performClose(nil)}));window.delegate=self;window.center()
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
    func windowShouldClose(_ sender:NSWindow)->Bool{
        if !model.busy{return true};let alert=NSAlert();alert.messageText="Отменить обработку и закрыть?";alert.informativeText="Уже готовые файлы останутся. Текущий результат не будет сохранён.";alert.addButton(withTitle:"Продолжить обработку");alert.addButton(withTitle:"Отменить и закрыть")
        if alert.runModal() == .alertSecondButtonReturn{model.cancel();return true};return false
    }
    func windowWillClose(_ notification:Notification){window?.contentView=nil;onClose?()}
}
