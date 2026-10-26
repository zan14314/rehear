import SwiftUI
import AVFoundation
import AppKit

struct DownloadModel:Decodable,Identifiable{
    var id:String;var file:String;var repo:String;var name:String;var kind:String;var memoryGB:Int;var detail:String;var size:Int64;var installed:Bool;var downloaded:Int64;var status:String;var error:String
    var downloading:Bool{status=="downloading" || status=="verifying"}
    var bytes:String{ByteCountFormatter.string(fromByteCount:size,countStyle:.file)}
}
struct ModelDownloadsView:View{
    @ObservedObject var store:Store
    var memory:Int{Int(ProcessInfo.processInfo.physicalMemory/1024/1024/1024)}
    func recommended(_ item:DownloadModel)->Bool{item.id==(memory<16 ? "whisper-small":"whisper-turbo") || (item.kind=="llm" && memory>=16)}
    var body:some View{
        VStack(alignment:.leading,spacing:16){
            Text("Модели для этого Mac").font(.headline)
            Text("Память: \(memory) ГБ · Apple Silicon. Модели работают локально и запускаются по очереди. Рекомендация по памяти — ориентир, скорость зависит от Mac и других приложений.").font(.caption).foregroundStyle(.secondary)
            ForEach(store.downloads.filter{recommended($0)}){item in modelRow(item)}
            DisclosureGroup("Другие совместимые модели"){ForEach(store.downloads.filter{!recommended($0)}){item in modelRow(item)}}
            Text("Скачивание идёт с Hugging Face по HTTPS. Аудио и тексты туда не отправляются. После загрузки интернет не нужен.").font(.caption).foregroundStyle(.secondary)
        }
    }
    func modelRow(_ item:DownloadModel)->some View{
        VStack(alignment:.leading,spacing:7){
            HStack{
                VStack(alignment:.leading,spacing:4){Text(item.name).fontWeight(.medium);Text(item.bytes+(recommended(item) ? " · Рекомендуем для этого Mac":"")+(memory<item.memoryGB ? " · Лучше от \(item.memoryGB) ГБ памяти":"")).font(.caption).foregroundStyle(.secondary)}
                Spacer()
                if item.downloading{Button("Отменить"){store.send(["action":"cancelDownload"])}}
                else if item.installed{if item.kind=="improve"{Text("Для улучшения").font(.caption).foregroundStyle(.secondary)}else{let selected=URL(fileURLWithPath:item.kind=="llm" ? store.titleModel:store.speechModel).lastPathComponent==item.file;Button(selected ? "Выбрана":"Использовать"){store.send(["action":"selectDownloadedModel","id":item.id])}.disabled(selected)}}
                else{Button(item.downloaded>0 ? "Продолжить":"Скачать"){store.send(["action":"downloadModel","id":item.id])}.disabled(store.downloads.contains{$0.downloading})}
            }
            Text(item.detail).font(.caption).foregroundStyle(.secondary)
            Link("Источник и лицензия",destination:URL(string:"https://huggingface.co/"+item.repo)!).font(.caption)
            if item.installed{Label("Установлена",systemImage:"checkmark.circle").font(.caption).foregroundStyle(.green)}
            if item.downloading{ProgressView(value:Double(item.downloaded),total:Double(item.size));Text(item.status=="verifying" ? "Проверяем целостность…":"\(ByteCountFormatter.string(fromByteCount:item.downloaded,countStyle:.file)) из \(item.bytes)").font(.caption).foregroundStyle(.secondary)}
            if !item.error.isEmpty{Text(item.error).font(.caption).foregroundStyle(.orange)}
        }.padding(12).background(Color.white.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
    }
}
struct SetupSheet:View{
    @ObservedObject var store:Store;@Binding var completed:Bool
    @Environment(\.dismiss) var dismiss
    @State var microphone=false;@State var screen=false
    var body:some View{
        VStack(alignment:.leading,spacing:18){
            Text("Настроим Rehear").font(.title2.bold())
            ScrollView{
                VStack(alignment:.leading,spacing:22){
                    VStack(alignment:.leading,spacing:8){Text("1. Папка разговоров").font(.headline);Text(store.folder).font(.caption).textSelection(.enabled);Button("Выбрать папку…"){let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true;if panel.runModal() == .OK,let url=panel.url{store.send(["action":"folder","path":url.path])}}}
                    ModelDownloadsView(store:store)
                    VStack(alignment:.leading,spacing:10){Text("Разрешения для записи").font(.headline);Text("Для импорта готовых файлов разрешения не нужны. Для записи включи нужные источники.").font(.caption).foregroundStyle(.secondary)
                        HStack{Label(microphone ? "Микрофон разрешён":"Микрофон",systemImage:microphone ? "checkmark.circle":"mic");Spacer();Button("Разрешить…"){Task{microphone=await AVCaptureDevice.requestAccess(for:.audio)}}.disabled(microphone)}
                        HStack{Label(screen ? "Системный звук разрешён":"Системный звук",systemImage:screen ? "checkmark.circle":"desktopcomputer");Spacer();Button("Разрешить…"){screen=CGRequestScreenCaptureAccess()}.disabled(screen)}
                        Text("macOS называет доступ к системному звуку «Запись экрана и системного аудио». Приложение сохраняет аудио. Если разрешение уже менялось, проверь его в настройках конфиденциальности macOS.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Открыть настройки конфиденциальности macOS…"){NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security")!)}
                    Text("После настройки запиши 10–15 секунд, останови запись и проверь звук и транскрипт. Саммари и чат требуют отдельной модели Qwen.").font(.callout)
                }.padding(.trailing,8)
            }
            HStack{Button("Позже"){dismiss()};Spacer();Button("Готово"){completed=true;dismiss()}.keyboardShortcut(.defaultAction).disabled(!store.ready)}
        }.padding(26).frame(width:660,height:680).preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)){_ in microphone=AVCaptureDevice.authorizationStatus(for:.audio) == .authorized;screen=CGPreflightScreenCaptureAccess()}
        .onAppear{microphone=AVCaptureDevice.authorizationStatus(for:.audio) == .authorized;screen=CGPreflightScreenCaptureAccess()}
    }
}

struct RecoveryRecording:Decodable,Identifiable{var id:String;var name:String;var size:Int64;var modified:Double}
struct FailureRecord:Decodable{var time:String;var stage:String;var code:String;var model:String;var kind:String}
struct TranscriptVersion:Decodable,Identifiable{var id:String;var created:Double;var label:String;var preview:String}
struct ReadinessView:View{
    @ObservedObject var store:Store;@Environment(\.dismiss) var dismiss
    @State var microphone=false;@State var screen=false;@State var free:Int64=0
    var folderOK:Bool{FileManager.default.isWritableFile(atPath:store.folder)}
    var body:some View{
        VStack(alignment:.leading,spacing:16){
            Text("Проверка и восстановление").font(.title2.bold())
            ScrollView{VStack(alignment:.leading,spacing:16){
                check("Совместимость","M1 и новее · macOS 15 или новее",true)
                HStack{check("Обработка",store.serviceHealthy ? "Сервис доступен":"Сервис не отвечает",store.serviceHealthy);Spacer();Button("Перезапустить обработку"){store.restartService()}.disabled(store.recording || store.startingRecording)}
                HStack{check("Папка",folderOK ? "Доступна для сохранения":"Папка недоступна",folderOK);Spacer();Button("Выбрать…"){store.chooseFolder();refresh()}.disabled(store.recording)}
                check("Место на диске",ByteCountFormatter.string(fromByteCount:free,countStyle:.file)+" свободно · для длинных записей оставь несколько ГБ",free>2*1024*1024*1024)
                check("Транскрибация",store.ready ? "Модель готова":"Скачай модель ниже. Сохранённые записи дождутся её загрузки.",store.ready)
                HStack{check("Микрофон",microphone ? "Разрешён":"Нужно разрешение для записи голоса",microphone);Spacer();Button("Разрешить"){Task{microphone=await AVCaptureDevice.requestAccess(for:.audio)}}.disabled(microphone)}
                HStack{check("Звук компьютера",screen ? "Разрешён":"Нужно разрешение macOS",screen);Spacer();Button("Разрешить"){screen=CGRequestScreenCaptureAccess()}.disabled(screen)}
                Button("Открыть настройки конфиденциальности…"){NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security")!)}
                Text("Для импорта готового аудио разрешения на запись не нужны.").font(.caption).foregroundStyle(.secondary)
                if !store.stateNotice.isEmpty{Text(store.stateNotice).font(.callout).foregroundStyle(.orange);Button("Понятно"){store.send(["action":"dismissStateNotice"])};Button("Восстановить список из выбранной папки"){store.send(["action":"recoverLibrary"])}}
                if !store.recoveries.isEmpty{
                    Divider();Text("Незавершённые записи").font(.headline)
                    ForEach(store.recoveries){row in HStack{VStack(alignment:.leading){Text(row.name).lineLimit(2);Text(ByteCountFormatter.string(fromByteCount:row.size,countStyle:.file)).font(.caption).foregroundStyle(.secondary)};Spacer();Button("Восстановить"){store.send(["action":"recoverRecording","id":row.id])}.disabled(store.recording || store.jobs.contains{$0.kind=="recovery" && ["queued","working","converting"].contains($0.status)})}}
                    Text("Исходные дорожки сохранятся. После восстановления запись автоматически отправится на транскрибацию.").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Модели"){ModelDownloadsView(store:store)}
                Divider()
                if let failure=store.lastFailure{Text("Последний сбой: \(failure.time) · \(failure.stage) · \(failure.code)").font(.caption).foregroundStyle(.secondary)}
                Button("Скопировать отчёт об ошибке"){store.copyDiagnostics()}
                Text("Отчёт не содержит аудио, текста разговоров, названий встреч и путей к файлам.").font(.caption).foregroundStyle(.secondary)
            }.padding(.trailing,8)}
            HStack{Button("Проверить снова"){refresh();store.send(["action":"scan"])};Spacer();Button("Готово"){dismiss()}.keyboardShortcut(.defaultAction)}
        }.padding(24).frame(width:680,height:680).preferredColorScheme(.dark).onAppear{refresh()}
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)){_ in refresh()}
    }
    func check(_ title:String,_ text:String,_ ok:Bool)->some View{HStack(alignment:.top,spacing:10){Image(systemName:ok ? "checkmark.circle":"exclamationmark.circle").foregroundStyle(ok ? .green:.orange);VStack(alignment:.leading,spacing:3){Text(title).font(.callout.weight(.medium));Text(text).font(.caption).foregroundStyle(.secondary)}}}
    func refresh(){microphone=AVCaptureDevice.authorizationStatus(for:.audio) == .authorized;screen=CGPreflightScreenCaptureAccess();if let attrs=try? FileManager.default.attributesOfFileSystem(forPath:store.folder),let bytes=attrs[.systemFreeSize] as? NSNumber{free=bytes.int64Value}}
}
struct TranscriptHistoryView:View{
    @ObservedObject var store:Store;let jobId:String;@Environment(\.dismiss) var dismiss
    @State var selected:TranscriptVersion?
    var body:some View{VStack(alignment:.leading,spacing:16){Text("История расшифровок").font(.title2.bold());Text("Основная карточка всегда показывает активную версию. При восстановлении текущая версия тоже останется в истории.").font(.caption).foregroundStyle(.secondary)
        ScrollView{VStack(alignment:.leading,spacing:16){if store.versionsJob != jobId{ProgressView()}else if store.versions.isEmpty{Text("Предыдущих версий пока нет").foregroundStyle(.secondary)}else{ForEach(store.versions){version in VStack(alignment:.leading,spacing:8){HStack{Text(version.label).font(.headline);Spacer();Button("Восстановить"){selected=version}};Text(version.preview).font(.callout).foregroundStyle(.secondary).lineLimit(5);Divider()}}}}}
        HStack{Spacer();Button("Закрыть"){dismiss()}}
    }.padding(24).frame(width:650,height:500).preferredColorScheme(.dark).onAppear{store.versionsJob="";store.send(["action":"versionHistory","id":jobId])}
    .confirmationDialog("Сделать эту расшифровку основной?",isPresented:Binding(get:{selected != nil},set:{if !$0{selected=nil}}),titleVisibility:.visible){Button("Восстановить"){if let selected{store.send(["action":"restoreTranscript","id":jobId,"versionId":selected.id]);dismiss()}}}}
}
