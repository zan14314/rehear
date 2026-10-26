import SwiftUI
import AppKit
import CoreText
import UniformTypeIdentifiers

func momentLink(_ id:String,_ seconds:Double)->String{"calls://meeting/\(id)?t=\(String(format:"%.2f",seconds))"}

struct JoinSelection:Identifiable{var id=UUID();var parts:[Call]}
struct JoinConversationsSheet:View{
    @ObservedObject var store:Store;@State var parts:[Call];@State var title="Объединённый разговор"
    @Environment(\.dismiss) var dismiss
    var body:some View{
        VStack(alignment:.leading,spacing:18){Text("Объединить разговоры").font(.title2.weight(.semibold));TextField("Название",text:$title)
            Text("Порядок частей · сверху вниз").font(.caption).foregroundStyle(.secondary)
            ScrollView{VStack(spacing:10){ForEach(Array(parts.enumerated()),id:\.element.id){index,part in HStack{Text("\(index+1)").foregroundStyle(.secondary).frame(width:22);VStack(alignment:.leading,spacing:4){Text(part.title ?? part.name).lineLimit(2);Text(store.durationLabel(part)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)};Spacer();Button{parts.swapAt(index,index-1)}label:{Image(systemName:"chevron.up")}.disabled(index==0);Button{parts.swapAt(index,index+1)}label:{Image(systemName:"chevron.down")}.disabled(index==parts.count-1)}.buttonStyle(.plain).padding(10).background(Color.white.opacity(0.04),in:RoundedRectangle(cornerRadius:8))}}}.frame(maxHeight:330)
            Text(parts.allSatisfy{store.durations[$0.id] != nil} ? "Общая длительность: \(compactDuration(parts.reduce(0){$0+(store.durations[$1.id] ?? 0)}))":"Общая длительность: уточняем…").font(.callout).foregroundStyle(.secondary)
            Text("Создадим отдельный разговор с общей записью и таймкодами. Исходные записи и их саммари останутся на месте. Саммари нового разговора создаётся отдельно.").font(.caption).foregroundStyle(.secondary)
            HStack{Button("Отмена"){dismiss()}.keyboardShortcut(.cancelAction);Spacer();Button("Объединить"){store.send(["action":"merge","ids":parts.map{$0.id},"title":title]);dismiss()}.keyboardShortcut(.defaultAction).disabled(parts.count<2 || title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}
        }.padding(26).frame(width:620).preferredColorScheme(.dark)
    }
}

struct ConversationExportSheet:View{
    @ObservedObject var model:NativeReaderModel
    @Environment(\.dismiss) var dismiss
    @State var content=0;@State var format="pdf";@State var timestamps=true;@State var error=""
    var body:some View{
        VStack(alignment:.leading,spacing:18){Text("Экспорт разговора").font(.title2.weight(.semibold))
            Picker("Содержание",selection:$content){Text("Таймкоды").tag(0);Text("Текст").tag(1);Text("Саммари").tag(2).disabled(model.summary.isEmpty)}.pickerStyle(.segmented)
            Picker("Формат",selection:$format){Text("PDF").tag("pdf");Text("TXT").tag("txt")}.pickerStyle(.segmented)
            if content==0{Toggle("С таймкодами",isOn:$timestamps)}
            if !error.isEmpty{Text(error).font(.caption).foregroundStyle(.orange)}
            HStack{Button("Отмена"){dismiss()};Spacer();Button("Сохранить…"){save()}.keyboardShortcut(.defaultAction)}
        }.padding(26).frame(width:450).preferredColorScheme(.dark)
    }
    func save(){
        let panel=NSSavePanel();panel.allowedContentTypes=[format=="pdf" ? .pdf:.plainText];panel.nameFieldStringValue=String(model.reader.title.prefix(140))+(content==2 ? " — саммари":content==1 ? " — текст":"")+"."+format
        guard panel.runModal() == .OK,let target=panel.url else{return}
        let text=content==2 ? model.summary:content==1 ? model.plainText:model.segments.map{timestamps ? "[\(readerStamp($0.start))]\n\($0.text)":$0.text}.joined(separator:"\n\n")
        do{if format=="pdf"{try ConversationPDF.write(title:model.reader.title,subtitle:content==2 ? "Саммари":content==1 ? "Текст":"Транскрипт",text:text,to:target)}else{try ((content==1 ? "":model.reader.title+"\n\n")+text+"\n").write(to:target,atomically:true,encoding:.utf8)};dismiss()}catch{self.error=error.localizedDescription}
    }
}

enum ConversationPDF{
    static func write(title:String,subtitle:String,text:String,to target:URL)throws{
        let document=NSMutableAttributedString(string:"")
        func append(_ value:String,size:CGFloat,bold:Bool=false,color:NSColor = .black,spacing:CGFloat=9){let style=NSMutableParagraphStyle();style.lineSpacing=4;style.paragraphSpacing=spacing;document.append(NSAttributedString(string:value+"\n",attributes:[.font:bold ? NSFont.boldSystemFont(ofSize:size):NSFont.systemFont(ofSize:size),.foregroundColor:color,.paragraphStyle:style]))}
        append(title,size:21,bold:true);append(subtitle,size:10,color:.gray)
        for line in text.components(separatedBy:.newlines){
            if line.trimmingCharacters(in:.whitespaces).isEmpty{continue}
            if line.range(of:"^\\[\\d{2}:\\d{2}:\\d{2}\\]$",options:.regularExpression) != nil{append(line,size:9,color:.gray,spacing:2)}else if line.hasPrefix("## "){append(String(line.dropFirst(3)),size:15,bold:true)}else{append(line.replacingOccurrences(of:"**",with:""),size:11)}
        }
        let setter=CTFramesetterCreateWithAttributedString(document);var page=CGRect(x:0,y:0,width:595.28,height:841.89)
        let temporary=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString+".pdf");defer{try? FileManager.default.removeItem(at:temporary)}
        guard let consumer=CGDataConsumer(url:temporary as CFURL),let context=CGContext(consumer:consumer,mediaBox:&page,[kCGPDFContextTitle:title] as CFDictionary) else{throw NSError(domain:"Rehear",code:1,userInfo:[NSLocalizedDescriptionKey:"Не удалось создать PDF"])}
        var location=0;var number=0
        repeat{
            context.beginPDFPage(nil);number += 1;context.setFillColor(CGColor(gray:1,alpha:1));context.fill(page)
            let path=CGPath(rect:CGRect(x:48,y:60,width:499.28,height:731.89),transform:nil);var frame=CTFramesetterCreateFrame(setter,CFRange(location:location,length:0),path,nil);var visible=CTFrameGetVisibleStringRange(frame)
            let pageText=(document.string as NSString).substring(with:NSRange(location:location,length:visible.length)) as NSString
            let orphan=pageText.range(of:"\\[\\d{2}:\\d{2}:\\d{2}\\]\\s*$",options:.regularExpression)
            if orphan.location != NSNotFound && orphan.location>0 && location+visible.length<document.length{visible.length=orphan.location;frame=CTFramesetterCreateFrame(setter,CFRange(location:location,length:visible.length),path,nil)}
            guard visible.length>0 else{context.endPDFPage();context.closePDF();throw NSError(domain:"Rehear",code:2,userInfo:[NSLocalizedDescriptionKey:"Текст не помещается на странице"])}
            context.textMatrix = .identity;CTFrameDraw(frame,context)
            let footer=NSAttributedString(string:"Rehear  ·  \(number)",attributes:[.font:NSFont.systemFont(ofSize:9),.foregroundColor:NSColor.gray]);context.textPosition=CGPoint(x:48,y:30);CTLineDraw(CTLineCreateWithAttributedString(footer),context)
            context.endPDFPage();location += visible.length
        }while location<document.length
        context.closePDF();try Data(contentsOf:temporary).write(to:target,options:.atomic)
    }
}

struct ConversationQuestion:Decodable,Identifiable{var id:String;var question:String;var answer:String;var sources:[QuestionSource];var revision:String}
struct QuestionSource:Decodable,Equatable{var start:Double;var text:String}
struct ChatDocument:Decodable{var hideSummary:Bool;var messages:[ChatMessage]}
struct ChatMessage:Decodable,Identifiable,Equatable{
    var id:String;var role:String;var text:String;var sources:[QuestionSource]
    var replyTo:String?=nil;var revision:String?=nil;var status:String?=nil
}
struct ConversationChatView:View{
    @ObservedObject var model:NativeReaderModel;@ObservedObject var store:Store
    var summaryBusy:Bool;var summaryJob:Call?
    @State var question="";@State var sending=false
    let accent=Color(red:0.64,green:0.48,blue:0.96)
    var job:Call?{store.jobs.last{$0.parentId==model.reader.jobId && $0.kind=="qa"}}
    var busy:Bool{job.map{["queued","working","converting"].contains($0.status)} ?? false}
    var body:some View{
        VStack(spacing:0){
            ScrollViewReader{proxy in
                ScrollView{VStack(alignment:.leading,spacing:20){
                    if !model.hideSummary && !model.summary.isEmpty{
                        VStack(alignment:.leading,spacing:12){Text("Краткое содержание").font(.caption.weight(.medium)).foregroundStyle(.secondary);StructuredSummaryView(text:model.summary)}
                            .padding(18).frame(maxWidth:.infinity,alignment:.leading)
                            .background(Color.white.opacity(0.035),in:RoundedRectangle(cornerRadius:14))
                            .contentShape(RoundedRectangle(cornerRadius:14))
                            .contextMenu{
                                Button("Скопировать"){copy(model.summary)}
                                Button("Пересоздать саммари"){store.send(["action":"summary","id":model.reader.jobId])}.disabled(summaryBusy)
                                Button("Удалить сообщение"){remove("summary")}
                            }

                    }
                    if model.summary.isEmpty && !summaryBusy{
                        Button("Создать краткое содержание"){store.send(["action":"summary","id":model.reader.jobId])}.buttonStyle(.bordered).frame(maxWidth:.infinity).padding(.vertical,20)
                    }
                    if summaryBusy{HStack{ProgressView().controlSize(.small);Text(summaryJob?.message ?? "Создаём саммари").font(.caption).foregroundStyle(.secondary);Spacer();Button("Отменить"){if let summaryJob{store.send(["action":"cancel","ids":[summaryJob.id]])}}}.padding(.vertical,10)}
                    ForEach(model.chatMessages){message in bubble(message)}
                    Color.clear.frame(height:1).id("chat-bottom")
                }.padding(.vertical,8)}
                .onChange(of:model.chatMessages){old,new in
                    if new.count>old.count || new.last?.text != old.last?.text{proxy.scrollTo("chat-bottom",anchor:.bottom)}
                    if sending && new.count>old.count{question="";sending=false}
                }
                .onAppear{if !model.chatMessages.isEmpty{proxy.scrollTo("chat-bottom",anchor:.bottom)}}
            }
            VStack(spacing:8){
                if busy{HStack{ProgressView().controlSize(.small);Text(job?.status=="queued" ? "В очереди":"Rehear отвечает…").font(.caption).foregroundStyle(.secondary);Spacer();Button("Остановить"){if let job{store.send(["action":"cancel","ids":[job.id]])}}.buttonStyle(.plain).font(.caption)}}
                if !store.error.isEmpty{Text(store.error).font(.caption).foregroundStyle(.orange).frame(maxWidth:.infinity,alignment:.leading)}
                HStack(spacing:12){TextField("Сообщение…",text:$question).textFieldStyle(.plain).onSubmit{ask()};Button{ask()}label:{Image(systemName:"arrow.up.circle.fill").font(.system(size:25)).foregroundStyle(accent)}.buttonStyle(.plain).accessibilityLabel("Отправить сообщение").help("Отправить сообщение").disabled(busy || sending || question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}
                    .padding(14).background(Color.white.opacity(0.06),in:RoundedRectangle(cornerRadius:13))
                Text("Локально · ответы проверяй по источникам").font(.system(size:11)).foregroundStyle(.tertiary).frame(maxWidth:.infinity,alignment:.leading)
            }.padding(.top,14)
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
        .onChange(of:store.error){_,value in if !value.isEmpty{sending=false}}
    }
    @ViewBuilder func bubble(_ message:ChatMessage)->some View{
        let own=message.role=="user"
        let generation=store.jobs.last{$0.chatMessageId==message.id}
        let working=generation.map{["queued","working"].contains($0.status)} ?? false
        let state=generation?.status ?? message.status ?? "done"
        HStack{if own{Spacer(minLength:70)}
            VStack(alignment:.leading,spacing:10){
                Text(own ? "Ты":"Rehear").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                if !message.text.isEmpty{Text((try? AttributedString(markdown:message.text,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))) ?? AttributedString(message.text)).font(.system(size:16)).lineSpacing(5)}
                if !own && message.text.isEmpty{Text(working ? "…":state=="cancelled" ? "Ответ остановлен":state=="error" ? (generation?.message ?? "Не удалось получить ответ"):"Ответ ожидается").foregroundStyle(.secondary)}
                if !own && working && !message.text.isEmpty{Text("Готовим новый ответ…").font(.caption).foregroundStyle(.secondary)}
                if !own,let revision=message.revision,revision != model.revision{Text("Транскрипт изменился после этого ответа").font(.caption).foregroundStyle(.orange)}
                if !message.sources.isEmpty{HStack{ForEach(Array(message.sources.prefix(6).enumerated()),id:\.offset){_,source in Button(readerStamp(source.start)){model.navigate(source.start,"")}.buttonStyle(.plain).font(.caption.monospacedDigit()).foregroundStyle(accent)}}}
            }.padding(16).frame(maxWidth:700,alignment:.leading)
                .background(own ? accent.opacity(0.16):Color.white.opacity(0.04),in:RoundedRectangle(cornerRadius:14))
                .contentShape(RoundedRectangle(cornerRadius:14))
                .contextMenu{ForEach(Array(actions(message).enumerated()),id:\.offset){_,action in Button(action.title,action:action.action).disabled(!action.enabled)}}
                .accessibilityElement(children:.contain).accessibilityLabel(own ? "Твоё сообщение":"Ответ Rehear")
            if !own{Spacer(minLength:40)}
        }.id(message.id)
    }
    func actions(_ message:ChatMessage)->[ChatMenuAction]{
        var result=[ChatMenuAction(title:"Скопировать",enabled:!message.text.isEmpty,action:{copy(message.text)})]
        if message.role=="assistant"{result.append(ChatMenuAction(title:"Перегенерировать ответ",enabled:!busy && model.chatMessages.contains{$0.id==message.replyTo && $0.role=="user"},action:{store.error="";store.send(["action":"regenerateAnswer","id":model.reader.jobId,"messageId":message.id])}))}
        result.append(ChatMenuAction(title:"Удалить сообщение",action:{remove(message.id)}));return result
    }
    func ask(){guard !busy,!sending,!question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{return};store.error="";sending=true;store.send(["action":"ask","id":model.reader.jobId,"question":String(question.prefix(500))])}
    func remove(_ key:String){store.send(["action":"deleteChatMessage","id":model.reader.jobId,"messageId":key])}
    func copy(_ text:String){NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)}
}
struct ChatMenuAction{var title:String;var enabled=true;var action:()->Void}
