import AppKit

/// The SIP-enabled implementation runs through Sunlight's existing canvas, in
/// a separate development bundle. It never enters the legacy setup/loader path.
enum SIPRedesign {
    @MainActor static var sourceDisplayIDs = Set<CGDirectDisplayID>()
    static let enabled = Bundle.main.object(forInfoDictionaryKey: "SunlightSIPRedesign") as? Bool == true
        || CommandLine.arguments.contains("--sip-redesign")

    static var supportName: String { enabled ? "Sunlight SIP Redesign" : "Sunlight" }

    @MainActor static func frameRate(displayID: CGDirectDisplayID) -> Int32 {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
        return Int32(max(1, screen?.maximumFramesPerSecond ?? 60))
    }

    static var statusURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(supportName, isDirectory: true).appendingPathComponent("redesign-session.json")
    }

    static func publish(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: statusURL, options: .atomic)
    }
}
