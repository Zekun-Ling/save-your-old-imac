// Parser robustness check that needs no XCTest (runs on a command-line-tools
// only install). The receiver listens on an unauthenticated TCP port, so the
// parser must survive any bytes without trapping. Run via Tests/run-fuzz.sh.
import Foundation
import LunaProto

struct LCG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 11
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    mutating func bytes(_ n: Int) -> Data { Data((0 ..< n).map { _ in UInt8(truncatingIfNeeded: next()) }) }
}

var rng = LCG(state: 0xC0FFEE)
var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if !cond { failures += 1; print("FAIL: \(msg)") }
}

let sps = Data([0x67, 0x64, 0x00, 0x1F, 0xAC])
let pps = Data([0x68, 0xEE, 0x3C, 0x80])
let valid: [Data] = [
    LunaWire.helloData(streamWidth: 3840, streamHeight: 2160, fps: 60, senderName: "MacBook"),
    LunaWire.capsData(screenWidth: 2560, screenHeight: 1440, name: "iMac", hasCamera: false, hasMic: false),
    LunaWire.paramSetsData(sps: sps, pps: pps),
    LunaWire.frameData(ptsMicros: 123, keyframe: true, avcc: rng.bytes(500)),
    LunaWire.frameData(ptsMicros: -1, keyframe: false, avcc: Data()),
    LunaWire.audioData(ptsMicros: 7, sampleRate: 48_000, channels: 2, pcm: rng.bytes(64)),
    LunaWire.captureData(camera: true, mic: true),
    LunaWire.captureStatusData(camera: "off", mic: "denied"),
]

// 1. Pure random bytes, random chunking.
var decoded = 0
for _ in 0 ..< 20_000 {
    let parser = LunaMessageParser()
    var data = rng.bytes(rng.below(600))
    while !data.isEmpty {
        let n = min(1 + rng.below(80), data.count)
        decoded += parser.feed(data.prefix(n)).count
        data = data.dropFirst(n)
    }
}

// 2. Valid packets with random bytes flipped, truncated, or spliced.
for _ in 0 ..< 60_000 {
    var pkt = valid[rng.below(valid.count)]
    for _ in 0 ..< 1 + rng.below(4) where !pkt.isEmpty {
        pkt[pkt.startIndex + rng.below(pkt.count)] = UInt8(truncatingIfNeeded: rng.next())
    }
    if rng.below(3) == 0 { pkt = pkt.prefix(rng.below(pkt.count + 1)) }
    if rng.below(4) == 0 { pkt.append(rng.bytes(rng.below(40))) }
    let parser = LunaMessageParser()
    _ = parser.feed(pkt)
    _ = parser.feed(valid[0])
}

// 3. Oversized length header must flag the stream as corrupt, not buffer it.
let hostile = LunaMessageParser()
_ = hostile.feed(Data([4, 0xFF, 0xFF, 0xFF, 0x7F]))
check(hostile.corrupted, "oversized length not flagged corrupt")
check(hostile.feed(valid[0]).isEmpty, "corrupt parser still produced messages")

// 4. Well-formed packets survive byte-at-a-time delivery.
let slow = LunaMessageParser()
var got: [LunaMessage] = []
for p in valid { for b in p { got += slow.feed(Data([b])) } }
check(got.count == valid.count, "byte-at-a-time got \(got.count) of \(valid.count) messages")

// 5. A batch of many empty unknown envelopes must not lose the following
// messages or the fragment at the read boundary.
var batch = Data(repeating: 0, count: 5 * 160_000)
batch.append(valid[0])
batch.append(valid[1].prefix(3))
let many = LunaMessageParser()
check(many.feed(batch) == [.hello(streamWidth: 3840, streamHeight: 2160, fps: 60, senderName: "MacBook")],
      "large batch lost its complete message")
check(many.feed(valid[1].dropFirst(3)) == [.caps(screenWidth: 2560, screenHeight: 1440, name: "iMac", hasCamera: false, hasMic: false)],
      "large batch lost the message spanning the read boundary")

print("parser-fuzz: \(failures == 0 ? "PASS" : "FAIL") (decoded \(decoded) messages from random noise, no crash)")
exit(failures == 0 ? 0 : 1)
