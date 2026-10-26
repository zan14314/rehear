import Foundation
@main struct FileLocator {
 static func main() {
  let input = FileHandle.standardInput.readDataToEndOfFile()
  guard let requests = try? JSONSerialization.jsonObject(with: input) as? [[String:String]] else { return }
  let results: [[String:String]] = requests.map { request in
   do {
    var url: URL
    if let encoded=request["bookmark"], let data=Data(base64Encoded:encoded) {
     var stale=false
     url=try URL(resolvingBookmarkData:data,options:[.withoutUI,.withoutMounting],relativeTo:nil,bookmarkDataIsStale:&stale)
    } else { url=URL(fileURLWithPath:request["path"] ?? "") }
    guard FileManager.default.fileExists(atPath:url.path), !url.path.contains("/.Trash/") else { return [:] }
    let data=try url.bookmarkData(options:[],includingResourceValuesForKeys:[.fileResourceIdentifierKey,.volumeIdentifierKey],relativeTo:nil)
    return ["path":url.path,"bookmark":data.base64EncodedString()]
   } catch { return [:] }
  }
  if let data=try? JSONSerialization.data(withJSONObject:results) { FileHandle.standardOutput.write(data) }
 }
}
