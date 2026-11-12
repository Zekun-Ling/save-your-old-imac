import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import LunaProto
import LunaMedia

/// Captures and encodes one virtual display, emitting wire-ready packets.
@available(macOS 12.3, *)
final class CaptureEncoder: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Config {
        var displayID: CGDirectDisplayID
        var streamWidth: Int
        var streamHeight: Int
        var fps: Int
        var bitrate: Int
    }

    private enum State { case idle, active, stopped }

    private let config: Config
    private let captureQueue = DispatchQueue(label: "luna.capture", qos: .userInteractive)
    // Capture discovery, stream ownership and VideoToolbox submissions share captureQueue.
    private var state: State = .idle
    private var stream: SCStream?
    private var encoder: H264Encoder?

    /// Configure callbacks before calling start().
    var onPacket: ((_ data: Data, _ tracePTS: Int64?) -> Void)?
    /// Return true when the network is backed up and this frame should be
    /// dropped before encoding (frame-rate adapts, stream stays valid).
    var shouldDropFrame: (() -> Bool)?
    var onStarted: (() -> Void)?
    var onError: ((String) -> Void)?

    init(config: Config) {
        self.config = config
        super.init()
    }

    func start() {
        // Give the new virtual display a moment to appear in ScreenCaptureKit.
        captureQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.state == .idle else { return }
            self.state = .active
            self.findDisplay(attempt: 0)
        }
    }

    private func findDisplay(attempt: Int) {
        guard state == .active else { return }
        if attempt > 0 {
            lunaLog("luna: retrying capture start (attempt %d)", attempt)
        }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            self?.captureQueue.async { [weak self] in
                guard let self, self.state == .active else { return }
                if let error {
                    self.onError?("Screen capture unavailable: \(error.localizedDescription)")
                } else if let display = content?.displays.first(where: { $0.displayID == self.config.displayID }) {
                    self.startStream(display: display)
                } else if attempt < 10 {
                    self.captureQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        self?.findDisplay(attempt: attempt + 1)
                    }
                } else {
                    self.onError?("Virtual display not found by ScreenCaptureKit")
                }
            }
        }
    }

    private func startStream(display: SCDisplay) {
        guard let encoder = H264Encoder(config: .init(
            width: config.streamWidth, height: config.streamHeight, fps: config.fps, bitrate: config.bitrate
        )) else {
            onError?("Could not create the H.264 encoder")
            return
        }
        encoder.onParameterSets = { [weak self] sps, pps in
            self?.onPacket?(LunaWire.paramSetsData(sps: sps, pps: pps), nil)
        }
        encoder.onEncodedFrame = { [weak self] pts, keyframe, avcc in
            let tracePTS = LatencyTrace.enabled ? pts : nil
            if let tracePTS { LatencyTrace.mark(.encoded, ptsMicros: tracePTS) }
            self?.onPacket?(LunaWire.frameData(ptsMicros: pts, keyframe: keyframe, avcc: avcc), tracePTS)
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let conf = SCStreamConfiguration()
        conf.width = config.streamWidth
        conf.height = config.streamHeight
        conf.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        conf.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        conf.showsCursor = true
        conf.queueDepth = 4

        let stream = SCStream(filter: filter, configuration: conf, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        } catch {
            onError?("Could not attach capture output: \(error.localizedDescription)")
            return
        }
        self.encoder = encoder
        self.stream = stream
        stream.startCapture { [weak self, weak stream] error in
            self?.captureQueue.async { [weak self, weak stream] in
                guard let self, let stream, self.stream === stream else { return }
                if let error {
                    self.onError?("Could not start capture: \(error.localizedDescription)")
                } else {
                    lunaLog("luna: capture started on display %u", self.config.displayID)
                    self.onStarted?()
                }
            }
        }
    }

    func stop() {
        captureQueue.sync {
            state = .stopped
            let activeStream = stream
            stream = nil
            activeStream?.stopCapture { _ in }
            encoder?.invalidate()
            encoder = nil
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard self.stream === stream,
              type == .screen,
              sampleBuffer.isValid,
              let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]])?.first,
              let statusRaw = attachments[SCStreamFrameInfo.status.rawValue] as? Int,
              statusRaw == SCFrameStatus.complete.rawValue,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let encoder
        else { return }

        guard shouldDropFrame?() != true else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if LatencyTrace.enabled, pts.isNumeric {
            LatencyTrace.mark(.captured, ptsMicros: Int64(CMTimeGetSeconds(pts) * 1_000_000))
        }
        encoder.encode(pixelBuffer, pts: pts)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        captureQueue.async { [weak self, weak stream] in
            guard let self, let stream, self.stream === stream else { return }
            self.onError?("Capture stopped: \(error.localizedDescription)")
        }
    }
}
