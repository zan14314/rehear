import SwiftUI
import AppKit
import AVFoundation
import CryptoKit

struct TranscriptionWarning:Decodable{var message:String;var start:Double;var end:Double}
struct TranscriptSegment:Decodable,Identifiable{var start:Double;var end:Double;var text:String;var id:Double{start}}
func readerStamp(_ time:Double)->String{let n=max(0,Int(time));return String(format:"%02d:%02d:%02d",n/3600,(n/60)%60,n%60)}
@MainActor final class NativeReaderModel:ObservableObject{
    let reader:Reader;let folder:URL
    @Published var transcriptionWarning:TranscriptionWarning?
    var lastSegmentsDate:Date?
    @Published var paragraphState=""
    @Published var plainParagraphs:[String]=[]
    @Published var plainText="";var lastPlainDate:Date?
    @Published var segments:[TranscriptSegment]=[];@Published var summary="";@Published var position=0.0;@Published var duration=0.0;@Published var playing=false;@Published var error=""
    @Published var navigationToken=0;var target:Double?;var targetQuery="";var targetPage=0;var revision=""
    var audio:AVAudioPlayer?;var timer:Timer?;var lastSummaryDate:Date?;var lastQuestionsDate:Date?
    @Published var chatMessages:[ChatMessage]=[];@Published var hideSummary=false;@Published var canUndo=false;@Published var canRedo=false;@Published var historyBusy=false
    init(_ reader:Reader){
        self.reader=reader;folder=URL(fileURLWithPath:reader.path).deletingLastPathComponent()
        do{segments=try JSONDecoder().decode([TranscriptSegment].self,from:Data(contentsOf:folder.appendingPathComponent(".segments.json")))}catch{self.error="Не удалось открыть текст: "+error.localizedDescription}
        if let data=try? Data(contentsOf:folder.appendingPathComponent(".transcription-warning.json")){transcriptionWarning=try? JSONDecoder().decode(TranscriptionWarning.self,from:data)}
        reload();target=reader.seek;targetQuery=reader.query;targetPage=reader.page
        refreshSummary();refreshChat();refreshPlain()
        timer=Timer.scheduledTimer(withTimeInterval:0.3,repeats:true){[weak self]_ in Task{@MainActor in guard let self else{return};if let audio=self.audio{if abs(self.position-audio.currentTime)>0.05{self.position=audio.currentTime};if self.playing != audio.isPlaying{self.playing=audio.isPlaying}};self.refreshTranscript();self.refreshSummary();self.refreshChat();self.refreshPlain()}}
    }
    func refreshTranscript(){let file=folder.appendingPathComponent(".segments.json");guard let date=try? file.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate,date != lastSegmentsDate else{return};reload()}
    func reload(){
        do{let file=folder.appendingPathComponent(".segments.json");let data=try Data(contentsOf:file);segments=try JSONDecoder().decode([TranscriptSegment].self,from:data);revision=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined();lastSegmentsDate=try? file.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate;refreshHistory()
            transcriptionWarning=nil
            if let warning=try? Data(contentsOf:folder.appendingPathComponent(".transcription-warning.json")){transcriptionWarning=try? JSONDecoder().decode(TranscriptionWarning.self,from:warning)}
            refreshSummary();refreshPlain()
        }catch{self.error=error.localizedDescription}
    }
    func navigate(_ start:Double?,_ query:String,_ page:Int=0){target=start;targetQuery=query;targetPage=page;navigationToken += 1;if let start{seek(start)}}
    func prepareAudio(){if audio != nil{return};do{audio=try AVAudioPlayer(contentsOf:folder.appendingPathComponent(".playback.m4a"));audio?.enableRate=true;audio?.prepareToPlay();duration=audio?.duration ?? 0}catch{self.error="Аудио для плеера не найдено"}}
    func toggle(){prepareAudio();if playing{audio?.pause()}else{audio?.play()};playing=audio?.isPlaying ?? false}
    func seek(_ value:Double,_ play:Bool=false){prepareAudio();audio?.currentTime=max(0,min(value,duration));position=audio?.currentTime ?? 0;if play{audio?.play();playing=audio?.isPlaying ?? false}}
    func refreshPlain(){let file=folder.appendingPathComponent("Сплошной текст.txt");guard let date=try? file.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate,date != lastPlainDate else{return};if let text=try? String(contentsOf:file,encoding:.utf8){plainText=text.trimmingCharacters(in:CharacterSet(charactersIn:"\u{feff}").union(.whitespacesAndNewlines));plainParagraphs=plainText.components(separatedBy:"\n\n").filter{!$0.isEmpty};lastPlainDate=date
        if let data=try? Data(contentsOf:folder.appendingPathComponent(".plain-meta.json")),let meta=try? JSONSerialization.jsonObject(with:data) as? [String:Any]{paragraphState=(meta["method"] as? String)=="quick" ? "Быстрая разбивка":(meta["structured"] as? Bool)==true ? "Абзацы уточнены":""}
    }}
    func refreshSummary(){let file=folder.appendingPathComponent("Краткое содержание.txt");guard let date=try? file.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate else{if !summary.isEmpty{summary=""};lastSummaryDate=nil;return};guard date != lastSummaryDate else{return};if let text=try? String(contentsOf:file,encoding:.utf8){summary=text.trimmingCharacters(in:CharacterSet(charactersIn:"\u{feff}").union(.whitespacesAndNewlines));lastSummaryDate=date}}
    func refreshHistory(){
        if let data=try? Data(contentsOf:folder.appendingPathComponent(".text-history.json")),let history=try? JSONSerialization.jsonObject(with:data) as? [String:[String]]{canUndo = !(history["undo"] ?? []).isEmpty;canRedo = !(history["redo"] ?? []).isEmpty}else{canUndo = !((try? FileManager.default.contentsOfDirectory(atPath:folder.appendingPathComponent(".text-versions").path)) ?? []).isEmpty;canRedo=false}
    }
    func refreshChat(){
        let file=folder.appendingPathComponent(".chat.json");let legacy=folder.appendingPathComponent(".questions.json");let source=FileManager.default.fileExists(atPath:file.path) ? file:legacy
        guard let date=try? source.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate,date != lastQuestionsDate else{return}
        if let data=try? Data(contentsOf:source){
            if source==file,let chat=try? JSONDecoder().decode(ChatDocument.self,from:data){chatMessages=chat.messages;hideSummary=chat.hideSummary;lastQuestionsDate=date}
            else if let entries=try? JSONDecoder().decode([ConversationQuestion].self,from:data){chatMessages=entries.flatMap{entry in [ChatMessage(id:entry.id+":user",role:"user",text:entry.question,sources:[]),ChatMessage(id:entry.id+":assistant",role:"assistant",text:entry.answer,sources:entry.sources,replyTo:entry.id+":user",revision:entry.revision,status:"done")]};lastQuestionsDate=date}
        }
    }
    func close(){timer?.invalidate();timer=nil;audio?.stop();audio=nil}
}
struct NativeReaderView:View{
    @ObservedObject var model:NativeReaderModel;@ObservedObject var store:Store
    @State var page=0;@State var query="";@State var speed=1.0;@State var editing:TranscriptSegment?;@State var replacing=false;@State var matchIndex=0;@State var exporting=false;@State var showHistory=false
    let accent=Color(red:0.64,green:0.48,blue:0.96)
    var summaryJob:Call?{store.jobs.last{$0.kind=="summary" && $0.parentId==model.reader.jobId}}
    var summaryBusy:Bool{summaryJob.map{["queued","working","converting"].contains($0.status)} ?? false}
    var visible:[TranscriptSegment]{model.segments}
    var matches:[TranscriptSegment]{query.isEmpty ? []:model.segments.filter{$0.text.localizedCaseInsensitiveContains(query)}}
    var body:some View{
        VStack(alignment:.leading,spacing:22){
            HStack(alignment:.top){Text(model.reader.title).font(.system(size:25,weight:.semibold)).fixedSize(horizontal:false,vertical:true);Spacer();HStack(spacing:14){
                if page==0{Button{history("undo")}label:{Image(systemName:"arrow.uturn.backward")}.buttonStyle(.plain).disabled(!model.canUndo || model.historyBusy).help("Отменить правку").accessibilityLabel("Отменить правку")
                Button{history("redo")}label:{Image(systemName:"arrow.uturn.forward")}.buttonStyle(.plain).disabled(!model.canRedo || model.historyBusy).help("Повторить правку").accessibilityLabel("Повторить правку")}
                Menu{
                Button("Скопировать текст"){copy(page==1 ? model.summary:page==2 ? model.plainText:model.segments.map{"[\(readerStamp($0.start))] \($0.text)"}.joined(separator:"\n\n"))}
                Divider()
                Button("Экспорт…"){exporting=true}
                Button("Открыть TXT"){openTranscriptTXT(page==2 ? model.folder.appendingPathComponent("Сплошной текст.txt").path:page==1 ? model.folder.appendingPathComponent("Краткое содержание.txt").path:model.reader.txt)}
                if model.hideSummary && !model.summary.isEmpty{Button("Показать саммари в чате"){store.send(["action":"showChatSummary","id":model.reader.jobId])}}
                Button("Показать папку"){NSWorkspace.shared.open(model.folder)}
                Button("История расшифровок…"){showHistory=true}
                Button(model.summary.isEmpty ? "Создать саммари":"Обновить саммари"){store.send(["action":"summary","id":model.reader.jobId]);page=1}.disabled(summaryBusy)
                if let original=store.jobs.first(where:{$0.id==model.reader.jobId}),original.kind != "improve"{Divider();Button("Улучшить транскрипт · large-v3"){store.send(["action":"improve","id":original.id])};if let improved=store.jobs.last(where:{$0.parentId==original.id && $0.kind=="improve" && $0.status=="done"}){Button("Открыть улучшенную версию"){store.send(["action":"reader","id":improved.id])}}}
            }label:{Image(systemName:"ellipsis").font(.title3)}.menuStyle(.borderlessButton).frame(width:32)}}
            HStack{Picker("Содержание",selection:$page){Text("Таймкоды").tag(0);Text("Текст").tag(2);Text("Саммари").tag(1)}.pickerStyle(.segmented).frame(width:310);Spacer();if page==0{HStack{Image(systemName:"magnifyingglass").foregroundStyle(.secondary);TextField("Найти в разговоре",text:$query).textFieldStyle(.plain);if !query.isEmpty{Text(matches.isEmpty ? "0":"\(min(matchIndex+1,matches.count))/\(matches.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary);Button{matchIndex=(matchIndex-1+matches.count)%max(1,matches.count)}label:{Image(systemName:"chevron.up")}.buttonStyle(.plain).disabled(matches.isEmpty).help("Предыдущее совпадение");Button{matchIndex=(matchIndex+1)%max(1,matches.count)}label:{Image(systemName:"chevron.down")}.buttonStyle(.plain).disabled(matches.isEmpty).help("Следующее совпадение");Button{query=""}label:{Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary)}.buttonStyle(.plain).help("Очистить поиск").accessibilityLabel("Очистить поиск") }}.padding(9).frame(width:350).background(Color.white.opacity(0.05),in:RoundedRectangle(cornerRadius:8))}}
            if let warning=model.transcriptionWarning{
                HStack(alignment:.top,spacing:10){Image(systemName:"exclamationmark.triangle").foregroundStyle(.orange);Text("В транскрипте обнаружены повторы · \(readerStamp(warning.start))–\(readerStamp(warning.end))").font(.caption).foregroundStyle(.secondary);Spacer();Button("Послушать"){model.seek(warning.start,true)};Button("Распознать заново"){store.send(["action":"repairTranscript","id":model.reader.jobId])}}.controlSize(.small)
            }
            if page==0{
                ScrollViewReader{proxy in ScrollView{LazyVStack(alignment:.leading,spacing:0){ForEach(visible){segment in HStack(alignment:.top,spacing:22){Button(readerStamp(segment.start)){model.seek(segment.start,true)}.buttonStyle(.plain).help("Слушать с этого места · правый клик для исправления текста").font(.system(size:12,design:.monospaced)).foregroundStyle(accent).frame(width:78,alignment:.leading).padding(.top,4);HighlightedTranscriptText(text:segment.text,query:query).font(.system(size:17)).lineSpacing(6).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}.contextMenu{Button("Исправить текст…"){editing=segment};Button("Заменить во всём разговоре…"){replacing=true};Button("Скопировать ссылку на момент"){copy(momentLink(model.reader.jobId,segment.start))};Button("Скопировать с таймкодом"){copy("[\(readerStamp(segment.start))] \(segment.text)")}}.id(segment.start).padding(.vertical,14).padding(.horizontal,12).background(TranscriptBlockContextMenu(onEdit:{editing=segment},onReplace:{replacing=true},onCopy:{copy("[\(readerStamp(segment.start))] \(segment.text)")},onLink:{copy(momentLink(model.reader.jobId,segment.start))})).background(model.playing && model.position>=segment.start && model.position<segment.end ? accent.opacity(0.09):Color.clear,in:RoundedRectangle(cornerRadius:8))}}}.onAppear{if let target=model.target{proxy.scrollTo(target,anchor:.center)}}.onChange(of:model.navigationToken){_,_ in page=model.targetPage;query=model.targetQuery;matchIndex=matches.firstIndex{$0.start==model.target} ?? 0;if let target=model.target{proxy.scrollTo(target,anchor:.center)}}.onChange(of:query){_,_ in matchIndex=matches.firstIndex{$0.start==model.target && query==model.targetQuery} ?? 0;if !matches.isEmpty{proxy.scrollTo(matches[min(matchIndex,matches.count-1)].start,anchor:.center)}}.onChange(of:matchIndex){_,value in if matches.indices.contains(value){proxy.scrollTo(matches[value].start,anchor:.center);model.seek(matches[value].start)}}}
            }else if page==2{
                VStack(alignment:.leading,spacing:12){
                    if !model.paragraphState.isEmpty{Text(model.paragraphState).font(.caption).foregroundStyle(.secondary)}
                    if let job=store.jobs.last(where:{$0.kind=="paragraphs" && $0.parentId==model.reader.jobId}),["queued","working"].contains(job.status){HStack{ProgressView().controlSize(.small);Text(job.status=="queued" ? "Абзацы готовы для чтения · уточнение в очереди":job.message).font(.caption).foregroundStyle(.secondary)}}
                    if let job=store.jobs.last(where:{$0.kind=="paragraphs" && $0.parentId==model.reader.jobId}),job.status=="error"{HStack{Text("Не удалось разбить на абзацы. Исходный текст сохранён.").font(.caption).foregroundStyle(.secondary);Button("Повторить"){store.send(["action":"plainText","id":model.reader.jobId])}}}
                    ScrollView{LazyVStack(alignment:.leading,spacing:18){ForEach(model.plainParagraphs.indices,id:\.self){index in Text(model.plainParagraphs[index]).font(.system(size:17)).lineSpacing(6).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}}.padding(.vertical,12)}
                }
            }else{
                ConversationChatView(model:model,store:store,summaryBusy:summaryBusy,summaryJob:summaryJob)

            }
            if !model.error.isEmpty{Text(model.error).font(.caption).foregroundStyle(.orange)}
            Divider().overlay(Color.white.opacity(0.03))
            HStack(spacing:16){Button{model.toggle()}label:{Image(systemName:model.playing ? "pause.fill":"play.fill").font(.title3).frame(width:36,height:36)}.buttonStyle(.plain).accessibilityLabel(model.playing ? "Пауза":"Воспроизвести");Text(readerStamp(model.position)).font(.caption.monospacedDigit()).foregroundStyle(.secondary);Slider(value:Binding(get:{model.position},set:{model.seek($0)}),in:0...max(1,model.duration));Text(readerStamp(model.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary);Menu{ForEach([0.75,1,1.25,1.5,2],id:\.self){rate in Button("\(rate.formatted())×"){speed=rate;model.audio?.rate=Float(rate)}}}label:{Text("\(speed.formatted())×").font(.callout)}.menuStyle(.borderlessButton).frame(width:65)}
        }.padding(30).background(Color(red:0.075,green:0.075,blue:0.09)).tint(accent).preferredColorScheme(.dark).frame(minWidth:780,minHeight:550).onAppear{page=model.targetPage;model.prepareAudio();query=model.targetQuery;if let start=model.target{model.seek(start)}}
        .onChange(of:model.navigationToken){_,_ in page=model.targetPage;query=model.targetQuery}
        .onChange(of:page){_,value in if value==2{store.send(["action":"plainText","id":model.reader.jobId]);model.refreshPlain()}}
        .onChange(of:store.editRevision){_,_ in if store.editedJob==model.reader.jobId{model.reload();model.historyBusy=false;editing=nil;replacing=false}}
        .onChange(of:store.error){_,value in if !value.isEmpty{model.historyBusy=false}}
        .sheet(item:$editing){segment in TranscriptEditSheet(model:model,store:store,segment:segment)}
        .sheet(isPresented:$showHistory){TranscriptHistoryView(store:store,jobId:model.reader.jobId)}
        .sheet(isPresented:$exporting){ConversationExportSheet(model:model,content:page==2 ? 1:page==1 ? 2:0)}
        .sheet(isPresented:$replacing){TranscriptEditSheet(model:model,store:store,segment:nil)}
    }
    func history(_ action:String){model.historyBusy=true;store.error="";store.send(["action":"editTranscript","id":model.reader.jobId,"revision":model.revision,"historyAction":action])}
    func copy(_ text:String){NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)}
}
@MainActor final class TranscriptWindowController:NSWindowController,NSWindowDelegate{
    var onClose:(()->Void)?;var resultFolder="";let model:NativeReaderModel
    init(reader:Reader,store:Store){
        model=NativeReaderModel(reader);resultFolder=model.folder.path
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:980,height:760),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title=reader.title;window.isReleasedWhenClosed=false;window.tabbingMode = .disallowed;window.minSize=NSSize(width:800,height:580)
        window.contentView=NSHostingView(rootView:NativeReaderView(model:model,store:store))
        super.init(window:window);window.delegate=self;window.center();window.setFrameAutosaveName("NativeTranscriptWindow");window.cascadeTopLeft(from:NSPoint(x:80,y:NSScreen.main?.visibleFrame.maxY ?? 800))
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
    func windowWillClose(_ notification:Notification){model.close();window?.contentView=nil;onClose?()}
}

struct StructuredSummaryView:View{
    let text:String
    let accent=Color(red:0.64,green:0.48,blue:0.96)
    var lines:[String]{text.components(separatedBy:.newlines).map{$0.trimmingCharacters(in:.whitespaces)}.filter{!$0.isEmpty}}
    var hasHeadings:Bool{lines.contains{$0.hasPrefix("#")}}
    var body:some View{
        VStack(alignment:.leading,spacing:14){
            if !hasHeadings{Text("Основные моменты").font(.title3.weight(.semibold)).padding(.bottom,6)}
            ForEach(Array(lines.enumerated()),id:\.offset){index,line in
                if line.hasPrefix("#"){
                    let heading=line.trimmingCharacters(in:CharacterSet(charactersIn:"# ")).components(separatedBy:" — ")
                    Text(heading[0]).font(.system(size:20,weight:.semibold)).foregroundStyle(accent).padding(.top,index==0 ? 0:16).padding(.bottom,4)
                    if heading.count>1{Text(heading.dropFirst().joined(separator:" — ")).font(.system(size:17)).lineSpacing(6)}
                }else{
                    let bullet=line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") || !hasHeadings
                    let content=line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") ? String(line.dropFirst(2)):line
                    HStack(alignment:.top,spacing:12){if bullet{Circle().fill(accent.opacity(0.7)).frame(width:5,height:5).padding(.top,10)};Text((try? AttributedString(markdown:content,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))) ?? AttributedString(content)).font(.system(size:17)).lineSpacing(6).frame(maxWidth:.infinity,alignment:.leading)}
                }
            }
        }.padding(.horizontal,8)
    }
}

struct HighlightedTranscriptText:View{
    var text:String;var query:String
    var highlighted:AttributedString{
        var result=AttributedString(text)
        guard !query.isEmpty else{return result}
        var range=text.startIndex..<text.endIndex
        while let found=text.range(of:query,options:[.caseInsensitive,.diacriticInsensitive],range:range){
            if let a=AttributedString.Index(found.lowerBound,within:result),let b=AttributedString.Index(found.upperBound,within:result){result[a..<b].backgroundColor=Color.purple.opacity(0.4)}
            guard found.upperBound<text.endIndex else{break};range=found.upperBound..<text.endIndex
        }
        return result
    }
    var body:some View{Text(highlighted)}
}
struct TranscriptSearchResults:View{
    @ObservedObject var store:Store;var query:String
    @State var limit=100
    var body:some View{
        VStack(alignment:.leading,spacing:12){
            if store.searchBusy{ProgressView("Ищем в названиях и тексте…").controlSize(.small)}else{Text(store.searchHits.isEmpty ? "Ничего не найдено":"Найдено: \(store.searchHits.count)").font(.caption).foregroundStyle(.secondary)}
            ScrollView{LazyVStack(alignment:.leading,spacing:8){ForEach(Array(store.searchHits.prefix(limit))){hit in
                Button{var command:[String:Any] = ["action":"reader","id":hit.jobId,"query":hit.start==nil ? "":query];if let start=hit.start{command["seek"]=start};store.send(command)}label:{
                    VStack(alignment:.leading,spacing:7){HStack{Text(hit.title).font(.headline).lineLimit(1);Spacer();if let start=hit.start{Text(readerStamp(start)).font(.caption.monospacedDigit()).foregroundStyle(.purple)}};HighlightedTranscriptText(text:hit.text,query:query).font(.callout).lineLimit(3).foregroundStyle(.secondary)}.frame(maxWidth:.infinity,alignment:.leading).padding(14).background(Color.white.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
                }.buttonStyle(.plain).help("Открыть найденное место")
            };if store.searchHits.count>limit{Button("Ещё совпадения"){limit += 100}.padding()}}}
        }.onChange(of:query){_,_ in limit=100}
    }
}

struct TranscriptEditSheet:View{
    @ObservedObject var model:NativeReaderModel;@ObservedObject var store:Store;var segment:TranscriptSegment?
    @Environment(\.dismiss) var dismiss
    @State var text="";@State var find="";@State var replacement="";@State var dictionary=false;@State var saving=false
    var body:some View{
        VStack(alignment:.leading,spacing:18){
            Text(segment==nil ? "Заменить в разговоре":"Исправить фрагмент").font(.title2.weight(.semibold))
            if let segment{Text(readerStamp(segment.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary);TextEditor(text:$text).font(.body).frame(minHeight:180)}else{
                TextField("Найти · точное совпадение",text:$find);TextField("Заменить на",text:$replacement)
                Toggle("Добавить исправленный термин в словарь",isOn:$dictionary)
                Text("Совпадений: \(find.isEmpty ? 0:model.segments.reduce(0){$0+$1.text.components(separatedBy:find).count-1})").font(.caption).foregroundStyle(.secondary)
            }
            Text("Предыдущая версия сохранится. Таймкоды останутся прежними. Готовое саммари обновляется отдельно.").font(.caption).foregroundStyle(.secondary)
            if !store.error.isEmpty{Text(store.error).font(.caption).foregroundStyle(.orange)}
            HStack{Button("Отмена"){dismiss()}.keyboardShortcut(.cancelAction);Spacer();Button(saving ? "Сохраняем…":"Сохранить"){
                store.error="";saving=true
                var command:[String:Any] = ["action":"editTranscript","id":model.reader.jobId,"revision":model.revision]
                if let segment{command["start"]=segment.start;command["text"]=text}else{command["find"]=find;command["replacement"]=replacement;command["dictionary"]=dictionary}
                store.send(command)
            }.keyboardShortcut(.defaultAction).disabled(saving || (segment==nil ? find.isEmpty:text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty))}
        }.padding(26).frame(width:550).onAppear{text=segment?.text ?? ""}.onChange(of:store.error){_,error in if !error.isEmpty{saving=false}}
    }
}

// Intercept only contextual clicks inside the visible row. NSTextView otherwise
// consumes these before the SwiftUI parent menu; ordinary text selection is untouched.
struct TranscriptBlockContextMenu:NSViewRepresentable{
    var onEdit:()->Void;var onReplace:()->Void;var onCopy:()->Void;var onLink:()->Void
    func makeNSView(context:Context)->TranscriptBlockMenuView{let view=TranscriptBlockMenuView();updateNSView(view,context:context);return view}
    func updateNSView(_ view:TranscriptBlockMenuView,context:Context){view.onEdit=onEdit;view.onReplace=onReplace;view.onCopy=onCopy;view.onLink=onLink}
    static func dismantleNSView(_ view:TranscriptBlockMenuView,coordinator:()){view.removeMonitor()}
}
final class TranscriptBlockMenuView:NSView{
    var onEdit:(()->Void)?;var onReplace:(()->Void)?;var onCopy:(()->Void)?;var onLink:(()->Void)?;var monitor:Any?
    override func hitTest(_ point:NSPoint)->NSView?{nil}
    override func viewDidMoveToWindow(){
        super.viewDidMoveToWindow();removeMonitor();guard window != nil else{return}
        monitor=NSEvent.addLocalMonitorForEvents(matching:[.rightMouseDown,.leftMouseDown]){[weak self] event in
            guard let self,let window=self.window,event.window===window,
                  event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                  !self.isHiddenOrHasHiddenAncestor,
                  self.visibleRect.contains(self.convert(event.locationInWindow,from:nil)) else{return event}
            let menu=NSMenu()
            for (title,selector) in [("Исправить текст…",#selector(self.edit)),("Заменить во всём разговоре…",#selector(self.replace)),("Скопировать ссылку на момент",#selector(self.copyLink)),("Скопировать с таймкодом",#selector(self.copyBlock))]{let item=NSMenuItem(title:title,action:selector,keyEquivalent:"");item.target=self;menu.addItem(item)}
            menu.popUp(positioning:nil,at:self.convert(event.locationInWindow,from:nil),in:self)
            return nil
        }
    }
    func removeMonitor(){if let monitor{NSEvent.removeMonitor(monitor);self.monitor=nil}}
    deinit{removeMonitor()}
    @objc func edit(){onEdit?()}
    @objc func replace(){onReplace?()}
    @objc func copyLink(){onLink?()}
    @objc func copyBlock(){onCopy?()}
}
