import Foundation
import AppKit
import CoreAudio
import ScreenCaptureKit
import SwiftUI

struct SystemAudioApp:Identifiable,Equatable{
    var id:String;var name:String
}
enum SystemAudioDiscovery{
    static func scalar(_ object:AudioObjectID,_ selector:AudioObjectPropertySelector,_ initial:UInt32=0)->UInt32{
        var address=AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var value=initial;var size=UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object,&address,0,nil,&size,&value)==noErr else{return initial};return value
    }
    static func bundleID(_ object:AudioObjectID)->String{
        var address=AudioObjectPropertyAddress(mSelector:kAudioProcessPropertyBundleID,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var value:Unmanaged<CFString>?;var size=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object,&address,0,nil,&size,&value)==noErr else{return ""}
        return value?.takeRetainedValue() as String? ?? ""
    }
    static func family(_ app:NSRunningApplication)->(String,String)?{
        if let url=app.bundleURL{
            // Electron/Chromium audio helpers live inside their main .app.
            var root=URL(fileURLWithPath:"/")
            for part in url.pathComponents.dropFirst(){
                root.appendPathComponent(part)
                if root.pathExtension=="app",let bundle=Bundle(url:root),let id=bundle.bundleIdentifier{
                    let main=NSRunningApplication.runningApplications(withBundleIdentifier:id).first
                    let name=main?.localizedName ?? bundle.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey:"CFBundleName") as? String ?? root.deletingPathExtension().lastPathComponent
                    return (id,name)
                }
            }
        }
        guard let id=app.bundleIdentifier else{return nil}
        return (id,app.localizedName ?? id)
    }
    static func activeApps()->[SystemAudioApp]{
        var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyProcessObjectList,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain);var size:UInt32=0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size)==noErr else{return []}
        var objects=[AudioObjectID](repeating:0,count:Int(size)/MemoryLayout<AudioObjectID>.size)
        guard !objects.isEmpty,AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&objects)==noErr else{return []}
        var apps=[String:SystemAudioApp]();let running=NSWorkspace.shared.runningApplications
        for object in objects where scalar(object,kAudioProcessPropertyIsRunningOutput,UInt32(0)) != 0{
            let pid=pid_t(bitPattern:scalar(object,kAudioProcessPropertyPID));let raw=bundleID(object)
            var candidate:NSRunningApplication?=NSRunningApplication(processIdentifier:pid)
            if candidate==nil{
                candidate=running.filter{app in guard let id=app.bundleIdentifier else{return false};return raw==id || raw.hasPrefix(id+".")}.max{($0.bundleIdentifier?.count ?? 0)<($1.bundleIdentifier?.count ?? 0)}
            }
            guard let app=candidate,let (id,name)=family(app),id != Bundle.main.bundleIdentifier else{continue}
            apps[id]=SystemAudioApp(id:id,name:name)
        }
        return apps.values.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}
    }
    static func matches(_ candidate:String,_ selected:String)->Bool{candidate==selected || candidate.hasPrefix(selected+".")}
    static func filter(_ content:SCShareableContent,bundleID:String)throws->SCContentFilter{
        guard let display=content.displays.first else{throw NSError(domain:"Созвоны",code:1,userInfo:[NSLocalizedDescriptionKey:"Экран не найден"])}
        if bundleID.isEmpty{return SCContentFilter(display:display,excludingApplications:[],exceptingWindows:[])}
        let apps=content.applications.filter{matches($0.bundleIdentifier,bundleID)}
        guard !apps.isEmpty else{throw NSError(domain:"Созвоны",code:1,userInfo:[NSLocalizedDescriptionKey:"Выбранное приложение недоступно для записи. Открой его и повтори. Другие приложения не записываются."])}
        return SCContentFilter(display:display,including:apps,exceptingWindows:[])
    }
}
@MainActor final class SystemAudioSources:ObservableObject{
    @Published var apps:[SystemAudioApp]=[]
    @Published var selectedID="";@Published var selectedName="Весь системный звук";@Published var changing=false
    var timer:Timer?
    init(){refresh();timer=Timer.scheduledTimer(withTimeInterval:2,repeats:true){[weak self] _ in Task{@MainActor in self?.refresh()}}}
    func refresh(){let current=SystemAudioDiscovery.activeApps();if current != apps{apps=current}}
}
struct SystemAudioSourceMenu:View{
    @ObservedObject var store:Store;@ObservedObject var sources:SystemAudioSources
    init(store:Store){self.store=store;self.sources=store.systemSources}
    var body:some View{
        Menu{
            Button((sources.selectedID.isEmpty ? "✓ ":"")+"Весь системный звук"){store.selectSystemSource("","Весь системный звук")}
            Divider()
            if sources.apps.isEmpty{Text("Нет приложений с активным аудиопотоком")}
            ForEach(sources.apps){app in Button((sources.selectedID==app.id ? "✓ ":"")+app.name){store.selectSystemSource(app.id,app.name)}}
            if !sources.selectedID.isEmpty && !sources.apps.contains(where:{$0.id==sources.selectedID}){Divider();Text("✓ "+sources.selectedName+" · нет активного аудиопотока")}
            Divider();Text("Список по активным аудиопотокам macOS")
        }label:{Text(sources.changing ? "Переключаем…":sources.selectedName).font(.caption).lineLimit(1).truncationMode(.middle).frame(width:170)}.menuStyle(.borderlessButton).frame(width:170).disabled(sources.changing || store.startingRecording || store.finishingRecording).help("Выбрать приложение для записи звука · можно во время записи. Пауза в приложении не всегда закрывает его аудиопоток.")
    }
}
