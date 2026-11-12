import AppKit
import CoreGraphics

// --selftest: verify all presets through the same display setup as a
// streaming session, without Screen Recording or a receiver.
@MainActor
func runDisplaySelftest() async -> Int32 {
    func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = DispatchTime.now() + 2
        while !condition() {
            guard DispatchTime.now() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    let vd = VirtualDisplaySession()
    var passed = 0
    for preset in DisplayPreset.allCases {
        print("SELFTEST \(preset.rawValue)")
        let pixels = preset.displayPixels
        let scale = preset.hiDPI ? 2 : 1
        guard vd.create(
            pixelWidth: pixels.width, pixelHeight: pixels.height,
            hiDPI: preset.hiDPI, refreshHz: Double(DisplayPreset.fps),
            name: "Luna Selftest"
        ) else {
            print("  FAILED to create")
            continue
        }
        let id = vd.displayID
        let modeOK = await waitUntil {
            guard VirtualDisplaySession.isOnline(id) == true,
                  let mode = CGDisplayCopyDisplayMode(id) else { return false }
            return mode.width == Int(pixels.width) / scale && mode.height == Int(pixels.height) / scale &&
                mode.pixelWidth == Int(pixels.width) && mode.pixelHeight == Int(pixels.height) &&
                abs(mode.refreshRate - Double(DisplayPreset.fps)) < 0.5
        }
        if let mode = CGDisplayCopyDisplayMode(id) {
            print("  current: \(mode.width)x\(mode.height) points, \(mode.pixelWidth)x\(mode.pixelHeight) pixels, \(mode.refreshRate) Hz")
        }
        if !modeOK { print("  FAILED to register the expected online display mode") }
        vd.destroy()
        let removed = await waitUntil { VirtualDisplaySession.isOnline(id) == false }
        if !removed { print("  FAILED to remove the virtual display") }
        if modeOK && removed { passed += 1 }
    }
    let total = DisplayPreset.allCases.count
    print("SELFTEST \(passed == total ? "PASS" : "FAIL") — \(passed)/\(total) production presets registered and removed")
    return passed == total ? 0 : 1
}

let app = NSApplication.shared
if CommandLine.arguments.contains("--selftest") {
    // Run AppKit's event loop so CoreGraphics sees display topology changes.
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in
        let result = await runDisplaySelftest()
        exit(result)
    }
    app.run()
} else if #available(macOS 13.0, *) {
    let delegate = SenderAppDelegate()
    app.delegate = delegate
    app.run()
} else {
    fputs("LunaSender requires macOS 13 or newer.\n", stderr)
    exit(1)
}
