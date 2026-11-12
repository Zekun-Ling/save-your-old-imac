import Foundation
import LunaProto
import AVFoundation
import CoreMedia

/// Feeds compressed H.264 samples straight into an AVSampleBufferDisplayLayer,
/// which hardware-decodes internally. No VTDecompressionSession needed, and
/// it works back to old macOS on the iMac.
final class VideoPipeline {
    let layer = AVSampleBufferDisplayLayer()
    private var formatDescription: CMVideoFormatDescription?
    private var needsKeyframe = true

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    func reset() {
        formatDescription = nil
        needsKeyframe = true
        layer.flushAndRemoveImage()
    }

    static func supportsSize(width: Int, height: Int) -> Bool {
        // Leave room above Luna's 4K preset while bounding decoder surfaces.
        (16...8192).contains(width) && (16...8192).contains(height) &&
            width * height <= 16_777_216
    }

    func setParameterSets(sps: Data, pps: Data) {
        formatDescription = nil
        needsKeyframe = true
        guard let spsType = sps.first, spsType & 0x1F == 7,
              let ppsType = pps.first, ppsType & 0x1F == 8 else { return }

        var desc: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsBase = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsRaw.bindMemory(to: UInt8.self).baseAddress
                else { return OSStatus(-1) }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc
                )
            }
        }
        guard status == noErr, let desc else {
            lunaLog("luna: could not create format description (%d)", status)
            return
        }
        let size = CMVideoFormatDescriptionGetDimensions(desc)
        guard Self.supportsSize(width: Int(size.width), height: Int(size.height)) else { return }
        formatDescription = desc
        layer.flush()
    }

    func enqueue(ptsMicros: Int64, keyframe: Bool, data: Data) -> Bool {
        guard let formatDescription else { return false }

        if #available(macOS 11.0, *), layer.requiresFlushToResumeDecoding {
            layer.flush()
            needsKeyframe = true
        }
        if layer.status == .failed {
            lunaLog("luna: display layer failed (%@), flushing", layer.error?.localizedDescription ?? "?")
            layer.flush()
            needsKeyframe = true
        }
        guard !needsKeyframe || keyframe else { return false }
        guard let hasIDR = Self.validateAVCC(data) else {
            needsKeyframe = true
            return false
        }
        guard !needsKeyframe || hasIDR else { return false }
        needsKeyframe = true

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { return false }

        status = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard status == noErr else { return false }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: ptsMicros, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return false }

        // Render as soon as decoded; we chase lowest latency, not smoothness.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }

        layer.enqueue(sampleBuffer)
        LatencyTrace.mark(.enqueued, ptsMicros: ptsMicros)
        needsKeyframe = false
        return true
    }

    /// Validate AVCC lengths before handing network bytes to Core Media.
    /// A well-formed access unit returns whether it contains an IDR picture.
    private static func validateAVCC(_ data: Data) -> Bool? {
        data.withUnsafeBytes { bytes in
            guard !bytes.isEmpty else { return nil }
            var offset = 0
            var hasIDR = false
            while offset < bytes.count {
                guard bytes.count - offset >= 5 else { return nil }
                let length = (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16) |
                    (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
                offset += 4
                guard length > 0, length <= bytes.count - offset else { return nil }
                if bytes[offset] & 0x1F == 5 { hasIDR = true }
                offset += length
            }
            return hasIDR
        }
    }
}
