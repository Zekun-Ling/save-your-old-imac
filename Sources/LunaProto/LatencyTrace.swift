import Dispatch
import Foundation

/// Developer diagnostics. Match stages by the existing wire PTS. The clocks
/// are comparable across processes on the same Mac, or within one process.
public enum LatencyTrace {
    public enum Stage: String {
        case captured, encoded, sent, received, enqueued
    }

    public static let enabled = ProcessInfo.processInfo.environment["LUNA_TRACE_LATENCY"] == "1"

    public static func mark(_ stage: Stage, ptsMicros: Int64) {
        guard enabled, ptsMicros >= 0, ptsMicros % 1_000_000 < 50_000 else { return }
        let nanos = DispatchTime.now().uptimeNanoseconds
        lunaLog("luna-latency: %@ pts_us=%lld uptime_ns=%llu", stage.rawValue, ptsMicros, nanos)
    }
}
