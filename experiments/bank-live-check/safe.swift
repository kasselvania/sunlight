// safe <x> <y> [margin]: exit 1 (and say which) if any UserNotificationCenter window (a consent prompt) is within margin of the point.
import AppKit
let a = CommandLine.arguments
let p = CGPoint(x: Double(a[1])!, y: Double(a[2])!), m = a.count > 3 ? Double(a[3])! : 30
for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]] {
  guard (w[kCGWindowOwnerName as String] as? String) == "UserNotificationCenter",
        let b = CGRect(dictionaryRepresentation: w[kCGWindowBounds as String] as! CFDictionary) else { continue }
  if b.insetBy(dx: -m, dy: -m).contains(p) { print("UNSAFE: prompt at \(NSStringFromRect(b))"); exit(1) }
}
print("safe")
