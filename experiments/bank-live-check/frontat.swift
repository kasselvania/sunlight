// frontat <x> <y> <window id>: exit 0 only if that window is the frontmost ordinary window at the point.
import AppKit
let a = CommandLine.arguments; let p = CGPoint(x: Double(a[1])!, y: Double(a[2])!); let want = UInt32(a[3])!
for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]] {
  guard let b = CGRect(dictionaryRepresentation: w[kCGWindowBounds as String] as! CFDictionary), b.contains(p),
        ((w[kCGWindowLayer as String] as? Int) ?? 0) >= 0, (w[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
  let id = w[kCGWindowNumber as String] as! UInt32
  if id == want { print("ok"); exit(0) }
  if ((w[kCGWindowLayer as String] as? Int) ?? 0) == 0 || (w[kCGWindowOwnerName as String] as? String) == "UserNotificationCenter" { print("covered by \(w[kCGWindowOwnerName as String] ?? "?") \(id)"); exit(1) }
}
print("not found"); exit(1)
