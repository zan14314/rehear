import Foundation
import AppKit
import ImageIO
import CoreText
import UniformTypeIdentifiers
import Darwin

func problem(_ text:String)->NSError{NSError(domain:"FileTools",code:1,userInfo:[NSLocalizedDescriptionKey:text])}
func byteCount(_ url:URL)->Int64{((try? FileManager.default.attributesOfItem(atPath:url.path)[.size]) as? NSNumber)?.int64Value ?? 0}
@discardableResult func runTool(_ executable:String,_ args:[String],_ scratch:URL,allowFailure:Bool=false)throws->String{
    let p=Process();p.executableURL=URL(fileURLWithPath:executable);p.arguments=args
    let log=scratch.appendingPathComponent("process.log");FileManager.default.createFile(atPath:log.path,contents:nil)
    let handle=try FileHandle(forWritingTo:log);p.standardError=handle;p.standardOutput=handle;p.standardInput=FileHandle.nullDevice
    try p.run();p.waitUntilExit();try handle.close();let text=(try? String(contentsOf:log,encoding:.utf8)) ?? ""
    if p.terminationStatus != 0 && !allowFailure{throw problem(String(text.suffix(1500)))};return text
}
func imageConvert(_ source:URL,_ out:URL,_ format:String,_ maxSide:Int,_ quality:Double,_ cap:Int64)throws->String{
    guard let input=CGImageSourceCreateWithURL(source as CFURL,nil),let props=CGImageSourceCopyPropertiesAtIndex(input,0,nil) as? [String:Any],let width=props[kCGImagePropertyPixelWidth as String] as? Int,let height=props[kCGImagePropertyPixelHeight as String] as? Int else{throw problem("Не удалось прочитать изображение")}
    let type:[String:String]=["jpeg":"public.jpeg","png":"public.png","heic":"public.heic"]
    guard let uti=type[format] else{throw problem("Неподдерживаемый формат изображения")}
    var side=maxSide>0 ? min(maxSide,max(width,height)):max(width,height)
    var usedQuality=quality;var finalWidth=0;var finalHeight=0
    for attempt in 0..<80{
        let options:[CFString:Any]=[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:side,kCGImageSourceShouldCacheImmediately:true]
        guard var image=CGImageSourceCreateThumbnailAtIndex(input,0,options as CFDictionary) else{throw problem("Не удалось изменить размер изображения")}
        if format != "png"{
            guard let context=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else{throw problem("Не удалось подготовить изображение")}
            context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:image.width,height:image.height));context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));image=context.makeImage()!
        }
        guard let destination=CGImageDestinationCreateWithURL(out as CFURL,uti as CFString,1,nil) else{throw problem("macOS не умеет сохранять этот формат")}
        CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality:usedQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else{throw problem("Не удалось сохранить изображение")}
        finalWidth=image.width;finalHeight=image.height
        if cap==0 || byteCount(out)<=cap{return "\(width)×\(height) → \(finalWidth)×\(finalHeight) · качество \(Int(usedQuality*100))%"}
        if format != "png" && usedQuality>0.38{usedQuality=max(0.35,usedQuality-0.10)}else{side=Int(Double(side)*0.80);usedQuality=quality}
        if side<64 || attempt==79{throw problem("Не получилось уложить изображение в заданный размер. Увеличь лимит.")}
    }
    throw problem("Не удалось обработать изображение")
}
func videoConvert(_ source:URL,_ out:URL,_ format:String,_ height:Int,_ quality:Double,_ cap:Int64,_ scratch:URL)throws->String{
    let ffmpeg=URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("ffmpeg").path
    let probe=try runTool(ffmpeg,["-hide_banner","-i",source.path],scratch,allowFailure:true)
    guard probe.contains("Video:") else{throw problem("В файле не найдена видеодорожка")}
    var duration:Double=0
    let re=try NSRegularExpression(pattern:"Duration: (\\d+):(\\d+):(\\d+(?:\\.\\d+)?)")
    if let match=re.firstMatch(in:probe,range:NSRange(probe.startIndex...,in:probe)){
        let ns=probe as NSString;duration=(Double(ns.substring(with:match.range(at:1))) ?? 0)*3600+(Double(ns.substring(with:match.range(at:2))) ?? 0)*60+(Double(ns.substring(with:match.range(at:3))) ?? 0)
    }
    let webm=format=="webm";let codec=webm ? "libvpx-vp9":"libx264";let crf=Int(18+(1-quality)*20)
    var common=["-nostdin","-y","-hide_banner","-i",source.path,"-map","0:v:0","-map","0:a:0?","-sn","-dn","-threads","4","-filter_threads","2"]
    let scale=height>0 ? "scale=-2:trunc(min(ih\\,\(height))/2)*2":"scale=trunc(iw/2)*2:trunc(ih/2)*2"
    common += ["-vf",scale,"-c:v",codec,"-pix_fmt","yuv420p"]
    common += webm ? ["-row-mt","1","-cpu-used","4"]:["-preset","medium"]
    let audio=["-c:a",webm ? "libopus":"aac","-b:a","96k","-ac","2"]
    let container=webm ? [String]():["-movflags","+faststart"]
    if cap>0{
        guard duration>0 else{throw problem("Не удалось определить длительность для заданного размера")}
        var bitrate=Int(Double(cap)*8/duration*0.93)-96000
        guard bitrate>=64000 else{throw problem("Заданный размер слишком мал для длительности видео. Увеличь лимит или отключи его.")}
        for retry in 0..<3{
            let pass=scratch.appendingPathComponent("video-pass-\(retry)").path
            let rate=["-b:v","\(bitrate)","-passlogfile",pass]
            try runTool(ffmpeg,common+rate+["-pass","1","-an","-f","null","/dev/null"],scratch)
            try runTool(ffmpeg,common+rate+["-pass","2"]+audio+container+[out.path],scratch)
            if byteCount(out)<=cap{return "Цель: не более \(Double(cap)/1_000_000) МБ · два прохода"}
            bitrate=Int(Double(bitrate)*0.85)
            if bitrate<64000{break}
        }
        throw problem("Не удалось уложить видео в лимит. Увеличь размер.")
    }
    let rate=webm ? ["-crf","\(crf)","-b:v","0"]:["-crf","\(crf)"]
    try runTool(ffmpeg,common+rate+audio+container+[out.path],scratch)
    return "\(height>0 ? "До \(height)p" : "Исходное разрешение") · \(webm ? "VP9":"H.264")"
}
func documentText(_ source:URL,_ fontSize:Double)throws->NSAttributedString{
    let ext=source.pathExtension.lowercased()
    if ["rtf","rtfd","docx","doc"].contains(ext){return try NSAttributedString(url:source,options:[:],documentAttributes:nil)}
    let data=try Data(contentsOf:source)
    guard data.count<=20_000_000 else{throw problem("Текст больше 20 МБ: выбери меньший документ")}
    var text=String(data:data,encoding:.utf8)
    if text==nil && data.starts(with:[0xff,0xfe]){text=String(data:data,encoding:.utf16LittleEndian)}
    if text==nil && data.starts(with:[0xfe,0xff]){text=String(data:data,encoding:.utf16BigEndian)}
    if text==nil{text=String(data:data,encoding:.windowsCP1251)}
    guard var value=text else{throw problem("Не удалось определить кодировку текста")}
    if value.first=="\u{feff}"{value.removeFirst()}
    let style=NSMutableParagraphStyle();style.lineSpacing=4;style.paragraphSpacing=6;style.lineBreakMode = .byWordWrapping
    return NSAttributedString(string:value,attributes:[.font:(NSFont(name:"Arial",size:fontSize) ?? NSFont.systemFont(ofSize:fontSize)),.foregroundColor:NSColor.black,.paragraphStyle:style])
}
func textPDF(_ source:URL,_ out:URL,_ fontSize:Double)throws->String{
    let text=try documentText(source,fontSize)
    guard text.length>0 else{throw problem("Документ пуст")}
    let setter=CTFramesetterCreateWithAttributedString(text)
    var page=CGRect(x:0,y:0,width:595.28,height:841.89)
    guard let consumer=CGDataConsumer(url:out as CFURL),let context=CGContext(consumer:consumer,mediaBox:&page,[kCGPDFContextTitle:source.deletingPathExtension().lastPathComponent] as CFDictionary) else{throw problem("Не удалось создать PDF")}
    var location=0;var count=0
    repeat{
        context.beginPDFPage(nil);count+=1
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(page)
        let path=CGPath(rect:CGRect(x:50,y:60,width:495.28,height:721.89),transform:nil)
        let frame=CTFramesetterCreateFrame(setter,CFRange(location:location,length:0),path,nil)
        let visible=CTFrameGetVisibleStringRange(frame)
        if visible.length==0{context.endPDFPage();context.closePDF();throw problem("Не удалось разместить текст на странице")}
        context.textMatrix = .identity;CTFrameDraw(frame,context)
        let footer=NSAttributedString(string:"\(count)",attributes:[.font:NSFont.systemFont(ofSize:10),.foregroundColor:NSColor.gray])
        context.textPosition=CGPoint(x:290,y:30);CTLineDraw(CTLineCreateWithAttributedString(footer),context)
        context.endPDFPage();location+=visible.length
        if count>3000{context.closePDF();throw problem("Документ слишком длинный")}
    }while location<text.length
    context.closePDF();return "A4 · страниц: \(count)"
}
@main struct Converter{
    static func main(){
        setpgid(0,0)
        do{
            let data=FileHandle.standardInput.readDataToEndOfFile();let c=try JSONSerialization.jsonObject(with:data) as! [String:Any]
            let source=URL(fileURLWithPath:c["source"] as! String),scratch=URL(fileURLWithPath:c["scratch"] as! String)
            let kind=c["kind"] as! String;let format=c["format"] as! String;let ext=format=="jpeg" ? "jpg":format
            guard FileManager.default.fileExists(atPath:source.path) else{throw problem("Исходный файл не найден")}
            let out=scratch.appendingPathComponent("converted."+ext)
            let quality=max(0.1,min(1,c["quality"] as? Double ?? 0.8));let target=c["targetMB"] as? Double ?? 0;guard target.isFinite && target>=0 && target<=100000 else{throw problem("Некорректный лимит размера")};let cap=Int64(target*1_000_000)
            let details:String
            switch kind{
            case "image":details=try imageConvert(source,out,format,c["maxSide"] as? Int ?? 0,quality,cap)
            case "video":details=try videoConvert(source,out,format,c["height"] as? Int ?? 0,quality,cap,scratch)
            case "text":details=try textPDF(source,out,c["fontSize"] as? Double ?? 12)
            case "archive":try runTool("/usr/bin/ditto",["-c","-k","--norsrc",source.path,out.path],scratch);details="ZIP · без изменения содержимого"
            default:throw problem("Неподдерживаемый тип")
            }
            guard byteCount(out)>0 else{throw problem("Результат пуст")}
            let value:[String:Any]=["ok":true,"file":out.path,"size":byteCount(out),"details":details]
            let encoded=try JSONSerialization.data(withJSONObject:value);FileHandle.standardOutput.write(encoded)
        }catch{
            let value:[String:Any]=["ok":false,"error":error.localizedDescription];if let encoded=try? JSONSerialization.data(withJSONObject:value){FileHandle.standardOutput.write(encoded)};exit(1)
        }
    }
}
