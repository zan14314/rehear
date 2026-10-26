import AppKit
let output=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
func render(_ size:Int)->Data{
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    let context=NSGraphicsContext(bitmapImageRep:bitmap)!;NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
    context.cgContext.scaleBy(x:CGFloat(size)/1024,y:CGFloat(size)/1024)
    let shape=NSBezierPath(roundedRect:NSRect(x:72,y:72,width:880,height:880),xRadius:200,yRadius:200)
    NSColor(calibratedRed:0.20,green:0.37,blue:0.91,alpha:1).setFill();shape.fill()
    NSGraphicsContext.saveGraphicsState();shape.addClip()
    let gradient=NSGradient(starting:NSColor(calibratedRed:0.19,green:0.55,blue:0.96,alpha:1),ending:NSColor(calibratedRed:0.39,green:0.24,blue:0.85,alpha:1))!;gradient.draw(in:NSRect(x:72,y:72,width:880,height:880),angle:-55)
    NSGraphicsContext.restoreGraphicsState()
    let heights:[CGFloat]=[100,220,390,540,340,180,100]
    NSColor.white.setFill()
    for (index,height) in heights.enumerated(){NSBezierPath(roundedRect:NSRect(x:234+CGFloat(index)*82,y:540-height/2,width:46,height:height),xRadius:23,yRadius:23).fill()}
    NSColor.white.withAlphaComponent(0.65).setFill();NSBezierPath(roundedRect:NSRect(x:338,y:220,width:348,height:24),xRadius:12,yRadius:12).fill()
    NSGraphicsContext.restoreGraphicsState();return bitmap.representation(using:.png,properties:[:])!
}
for size in [16,32,128,256,512]{try render(size).write(to:output.appendingPathComponent("icon_\(size)x\(size).png"));try render(size*2).write(to:output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))}
