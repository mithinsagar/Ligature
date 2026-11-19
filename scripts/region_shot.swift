// Captures the on-screen region of an app's window, including child panels (popovers, completion lists):
// swift region_shot.swift <AppName> <out.png> [window title substring]
import AppKit
let name = CommandLine.arguments[1], out = CommandLine.arguments[2]
let title = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : nil
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
var candidates = list.filter { ($0[kCGWindowOwnerName as String] as? String) == name && ($0[kCGWindowLayer as String] as? Int) == 0 }
if let title { candidates = candidates.filter { (($0[kCGWindowName as String] as? String) ?? "").contains(title) } }
func bounds(_ w: [String: Any]) -> CGRect {
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
}
guard let w = candidates.max(by: { bounds($0).width * bounds($0).height < bounds($1).width * bounds($1).height }) else { print("window not found"); exit(1) }
let r = bounds(w)
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
p.arguments = ["-x", "-R", "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))", out]
try! p.run(); p.waitUntilExit(); print("captured \(r)")
