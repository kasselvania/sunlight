import AppKit
import ScreenCaptureKit
import CoreMedia
import os
import SourceDisplay

/// One immutable capture geometry per stream. Reconfiguration starts a new
/// instance, so an old buffer can never be cropped using a new source rectangle.
/// SIP PERFORMANCE: backend configuration, newest-frame mailbox and delivery
/// counters are mapped in docs/sip-redesign-performance.md.
@MainActor
final class SourceBankCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private struct Mailbox: @unchecked Sendable { var buffer: CVPixelBuffer?; var scheduled = false; var received = 0; var width = 0; var height = 0 }
    nonisolated private let mailbox = OSAllocatedUnfairLock(initialState: Mailbox())
    nonisolated private static let samples = DispatchQueue(label: "sunlight.bank.frames", qos: .userInteractive)
    let source: CGRect
    /// Pixels per point it captures at.
    let scale: CGFloat
    private var stream: SCStream?
    private var displayStream: SLDisplayStream?
    private(set) var backend = "starting"
    private var starting = false
    private var screenCaptureStarted = false
    private var stopped = false
    private var began: CFTimeInterval?
    private(set) var presented = 0
    private(set) var running = false
    var onFrame: ((CVPixelBuffer, CGRect) -> Void)?
    var onError: ((String) -> Void)?
    var received: Int { mailbox.withLock { $0.received } }
    var pixelSize: CGSize { mailbox.withLock { CGSize(width: $0.width, height: $0.height) } }
    var elapsed: Double { began.map { CACurrentMediaTime() - $0 } ?? 0 }

    init(display: SCDisplay, source: CGRect, scale: CGFloat, fps: Int32) {
        self.source = source
        self.scale = scale
        super.init()
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = source.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = max(2, Int((source.width * scale).rounded()))
        config.height = max(2, Int((source.height * scale).rounded()))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false
        displayStream = SLDisplayStream(displayID: display.displayID,
            sourceRect: config.sourceRect, pixelSize: CGSize(width: config.width, height: config.height), queue: Self.samples)
        displayStream?.onFrame = { [weak self] buffer in self?.enqueue(buffer) }
        displayStream?.onStopped = { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.stopped, self.backend == "coregraphics" else { return }
                self.displayStream?.stop(); self.displayStream = nil
                self.running = false
                // A running feed stopping can mean its display disappeared.
                // Restore the bank; don't ask another API to capture a dead display.
                self.onError?("The source-display feed stopped.")
            }
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do { try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: Self.samples) }
        catch { onError?(error.localizedDescription); return }
        self.stream = stream
    }

    func start() {
        if displayStream?.start() == true {
            backend = "coregraphics"; running = true; began = CACurrentMediaTime()
        } else { displayStream = nil; startScreenCapture() }
    }

    private func startScreenCapture() {
        backend = "screencapturekit"
        guard let stream else { onError?("Could not attach the source-bank frame receiver."); return }
        starting = true
        stream.startCapture { [self] error in
            DispatchQueue.main.async {
                self.starting = false
                self.screenCaptureStarted = error == nil
                if self.stopped { self.stop(); return }
                if let error { self.onError?(error.localizedDescription) }
                else { self.running = true; self.began = CACurrentMediaTime() }
            }
        }
    }

    func stop() {
        stopped = true
        running = false
        displayStream?.stop(); displayStream = nil
        mailbox.withLock { $0.buffer = nil }
        guard !starting, let stream else { return }
        self.stream = nil
        guard screenCaptureStarted else { return }
        screenCaptureStarted = false
        stream.stopCapture { error in if let error { Log.note("Window bank: stopping capture failed: \(error)") } }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sample),
              let items = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              (items.first?[.status] as? NSNumber)?.intValue == SCFrameStatus.complete.rawValue,
              let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        enqueue(buffer)
    }

    // SIP PERFORMANCE: profile callback-to-main delay here and in present().
    // Retain newest-frame coalescing; frames_presented counts tile applications.
    nonisolated private func enqueue(_ buffer: CVPixelBuffer) {
        let frame = Mailbox(buffer: buffer)
        let schedule = mailbox.withLock { box in
            box.received += 1
            box.width = CVPixelBufferGetWidth(buffer); box.height = CVPixelBufferGetHeight(buffer)
            box.buffer = frame.buffer
            if box.scheduled { return false }
            box.scheduled = true
            return true
        }
        if schedule { DispatchQueue.main.async { [weak self] in self?.present() } }
    }

    private func present() {
        let taken = mailbox.withLock { box -> Mailbox in
            defer { box.buffer = nil; box.scheduled = false }
            return box
        }
        guard !stopped, let buffer = taken.buffer else { return }
        presented += 1
        onFrame?(buffer, source)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.running = false
            self.onError?(error.localizedDescription)
        }
    }
}
