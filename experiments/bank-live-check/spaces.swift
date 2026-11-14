// spaces: read-only map of Desktops (SkyLight) and the ordinary windows on each.
import AppKit
@_silgen_name("SLSMainConnectionID") func SLSMainConnectionID() -> Int32
@_silgen_name("SLSCopyManagedDisplaySpaces") func SLSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray
@_silgen_name("SLSCopySpacesForWindows") func SLSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> CFArray
let cid = SLSMainConnectionID()
let displays = SLSCopyManagedDisplaySpaces(cid) as! [[String: Any]]
for d in displays {
  let current = (d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int ?? -1
  print("display", d["Display Identifier"] ?? "?", "current space", current)
  for (i, s) in ((d["Spaces"] as? [[String: Any]]) ?? []).enumerated() {
    print("  desktop \(i + 1): id \(s["ManagedSpaceID"] ?? "?") type \(s["type"] ?? "?")\((s["ManagedSpaceID"] as? Int) == current ? "  ← current" : "")")
  }
}
let wins = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]).filter {
  ($0[kCGWindowLayer as String] as? Int) == 0 && (CGRect(dictionaryRepresentation: $0[kCGWindowBounds as String] as! CFDictionary)?.width ?? 0) > 200
}
for w in wins {
  let id = w[kCGWindowNumber as String] as! UInt32
  let spaces = SLSCopySpacesForWindows(cid, 0x7, [NSNumber(value: id)] as CFArray) as! [NSNumber]
  guard !spaces.isEmpty else { continue }
  print("window", id, w[kCGWindowOwnerName as String] ?? "?", "on spaces", spaces.map(\.intValue), (w[kCGWindowName as String] as? String).map { "“\($0.prefix(40))”" } ?? "")
}
