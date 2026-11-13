import AppKit
import ScreenCaptureKit
import CoreMedia
import os

/// One immutable capture geometry per stream. Reconfiguration starts a new
/// instance, so an old buffer can never be cropped using a new source rectangle.
@MainActor
final class SourceBankCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private struct Mailbox: @unchecked Sendable { var buffer: CVPixelBuffer?; var scheduled = false; var received = 0 }
    nonisolated private let mailbox = OSAllocatedUnfairLock(initialState: Mailbox())
    nonisolated private static let samples = DispatchQueue(label: "sunlight.bank.frames", qos: .userInteractive)
    let source: CGRect
    private var stream: SCStream?
    private var starting = false
    private var stopped = false
    private var began: CFTimeInterval?
    private(set) var presented = 0
    private(set) var running = false
    var onFrame: ((CVPixelBuffer, CGRect) -> Void)?
    var onError: ((String) -> Void)?
    var received: Int { mailbox.withLock { $0.received } }
    var elapsed: Double { began.map { CACurrentMediaTime() - $0 } ?? 0 }

    init(display: SCDisplay, windows: [SCWindow], source: CGRect, scale: CGFloat, fps: Int32) {
        self.source = source
        super.init()
        let filter = SCContentFilter(display: display, including: windows)
        let config = SCStreamConfiguration()
        config.sourceRect = source.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = max(2, Int((source.width * scale).rounded()))
        config.height = max(2, Int((source.height * scale).rounded()))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do { try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: Self.samples) }
        catch { onError?(error.localizedDescription); return }
        self.stream = stream
    }

    func start() {
        guard let stream else { onError?("Could not attach the source-bank frame receiver."); return }
        starting = true
        stream.startCapture { [self] error in
            DispatchQueue.main.async {
                self.starting = false
                if self.stopped { self.stop(); return }
                if let error { self.onError?(error.localizedDescription) }
                else { self.running = true; self.began = CACurrentMediaTime() }
            }
        }
    }

    func stop() {
        stopped = true
        running = false
        mailbox.withLock { $0.buffer = nil }
        guard !starting, let stream else { return }
        self.stream = nil
        stream.stopCapture { error in if let error { Log.note("Window bank: stopping capture failed: \(error)") } }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sample),
              let items = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              (items.first?[.status] as? NSNumber)?.intValue == SCFrameStatus.complete.rawValue,
              let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let frame = Mailbox(buffer: buffer)
        let schedule = mailbox.withLock { box in
            box.received += 1
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
