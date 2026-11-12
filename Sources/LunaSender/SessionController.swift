import Foundation
import AppKit
import Network
import IOKit.pwr_mgt
import LunaProto

/// Display presets. Stream size stays within 4096x2304 because the 2014
/// iMac's hardware can only H.264-decode up to ~4K; the receiver upscales
/// to its 5K panel, which matches how macOS scaled modes already work.
enum DisplayPreset: String, CaseIterable {
    case retina5KScaled
    case retina4K
    case plain1440

    static let fps = 60

    var title: String {
        switch self {
        case .retina5KScaled: return "Retina 5K scaled — looks like 2560×1440 (best)"
        case .retina4K: return "Retina 4K — looks like 1920×1080 (bigger UI)"
        case .plain1440: return "2560×1440 — non-Retina (lowest bandwidth)"
        }
    }

    var displayPixels: (width: UInt32, height: UInt32) {
        switch self {
        case .retina5KScaled: return (5120, 2880)
        case .retina4K: return (3840, 2160)
        case .plain1440: return (2560, 1440)
        }
    }

    var hiDPI: Bool {
        switch self {
        case .retina5KScaled, .retina4K: return true
        case .plain1440: return false
        }
    }

    var streamSize: (width: Int, height: Int) {
        switch self {
        case .retina5KScaled, .retina4K: return (3840, 2160)
        case .plain1440: return (2560, 1440)
        }
    }

    var bitrate: Int {
        switch self {
        case .retina5KScaled, .retina4K: return 70_000_000
        case .plain1440: return 40_000_000
        }
    }
}

/// Orchestrates one streaming session: connection -> virtual display ->
/// capture/encode -> packets over the wire.
@available(macOS 12.3, *)
final class SessionController {
    enum State: Equatable {
        case idle
        case connecting(String)
        case streaming(String)
    }

    private let virtualDisplay = VirtualDisplaySession()
    private var connection: SenderConnection?
    private var resolver: ServiceResolver?
    private var encoder: CaptureEncoder?
    private var sleepAssertion: IOPMAssertionID = 0
    private let fps = DisplayPreset.fps

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    var onStateChange: ((State) -> Void)?

    /// BSD name of the interface pinned in the menu; nil = automatic
    /// (wired first, then Wi-Fi).
    static var pinnedInterfaceName: String? {
        get {
            let name = UserDefaults.standard.string(forKey: "networkInterface") ?? ""
            return name.isEmpty ? nil : name
        }
        set { UserDefaults.standard.set(newValue ?? "", forKey: "networkInterface") }
    }

    /// "Thunderbolt Bridge (bridge0)" while connected, for the menu.
    private(set) var currentInterfaceLabel: String?
    /// Why the last connect attempt failed, shown in the menu while idle.
    private(set) var lastConnectError: String?

    /// Exposed for the --test-disconnect harness.
    var activeVirtualDisplayID: CGDirectDisplayID { virtualDisplay.displayID }

    /// Until the user picks a mode in the menu, stream at the panel size of a
    /// 1080p/1440p iMac (Late 2012/2013): 2560×1440 at 40 Mbps is far lighter
    /// on an older decoder and on Wi-Fi than the 4K/70 Mbps Retina modes.
    private var preset: DisplayPreset {
        DisplayPreset(rawValue: UserDefaults.standard.string(forKey: "preset") ?? "") ?? .plain1440
    }

    func connect(endpoint: NWEndpoint, name: String) {
        disconnect()
        lastConnectError = nil
        state = .connecting(name)

        let pinnedInterface: NWInterface?
        if let pinName = Self.pinnedInterfaceName {
            guard let interface = InterfaceMonitor.shared.interface(named: pinName) else {
                let error = "Pinned interface \(pinName) has no usable path"
                lastConnectError = error
                lunaLog("luna: %@", error)
                disconnect()
                return
            }
            pinnedInterface = interface
        } else {
            pinnedInterface = nil
        }

        // NWConnection stalls when a Bonjour service endpoint meets
        // prohibitedInterfaceTypes, so for the wired-first probe we resolve
        // the service to host:port ourselves and dial the host directly.
        // The plain service connect stays as the fallback.
        guard case .service(let sname, let stype, let sdomain, _) = endpoint else {
            attemptConnection(endpoint: endpoint, fallback: endpoint, name: name,
                              wiredOnly: pinnedInterface == nil, pinnedInterface: pinnedInterface)
            return
        }
        let resolveStarted = DispatchTime.now()
        let resolver = ServiceResolver { [weak self] resolver, result in
            guard let self, self.resolver === resolver else { return }
            self.resolver = nil
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - resolveStarted.uptimeNanoseconds) / 1_000_000
            if let result, let port = NWEndpoint.Port(rawValue: result.port) {
                lunaLog("luna: SRV resolved %@ -> %@:%d in %.1f ms (interface index %u)",
                        sname, result.host, Int(result.port), elapsed, result.interfaceIndex)
                self.attemptConnection(
                    endpoint: .hostPort(host: NWEndpoint.Host(result.host), port: port),
                    fallback: endpoint, name: name, wiredOnly: pinnedInterface == nil, pinnedInterface: pinnedInterface
                )
            } else {
                lunaLog("luna: SRV resolve failed after %.1f ms, connecting via service endpoint", elapsed)
                self.attemptConnection(endpoint: endpoint, fallback: endpoint, name: name,
                                       wiredOnly: false, pinnedInterface: pinnedInterface)
            }
        }
        self.resolver = resolver
        let interfaceIndex = pinnedInterface.flatMap { UInt32(exactly: $0.index) } ?? 0
        resolver.resolve(name: sname, type: stype, domain: sdomain, interfaceIndex: interfaceIndex)
    }

    /// Probe the wired path (Thunderbolt bridge / Ethernet) first; if none
    /// exists within a couple of seconds, reconnect over any interface.
    private func attemptConnection(endpoint: NWEndpoint, fallback: NWEndpoint, name: String,
                                   wiredOnly: Bool, pinnedInterface: NWInterface?) {
        let conn = SenderConnection(endpoint: endpoint, wiredOnly: wiredOnly, requiredInterface: pinnedInterface)
        let mode = pinnedInterface != nil ? "pinned" : (wiredOnly ? "wired probe" : "default routing")
        let connectStarted = DispatchTime.now()
        connection = conn
        var didConnect = false  // both callbacks fire on the main queue
        conn.onReady = { [weak self, weak conn] interface in
            guard let self, let conn, self.connection === conn else { return }
            didConnect = true
            self.currentInterfaceLabel = interface.map(InterfaceMonitor.label(for:)) ?? "unknown interface"
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - connectStarted.uptimeNanoseconds) / 1_000_000
            lunaLog("luna: connected via %@ (type %@, %@) in %.1f ms",
                    self.currentInterfaceLabel ?? "unknown interface",
                    interface.map { String(describing: $0.type) } ?? "unknown", mode, elapsed)
            self.onStateChange?(self.state)  // refresh the menu's "via" line
            self.handleConnected(name: name)
        }
        conn.onClosed = { [weak self, weak conn] reason in
            // Only react to the connection we currently own; a connection we
            // already replaced reporting closure must not kill the new one.
            guard let self, let conn, self.connection === conn else { return }
            if let reason {
                if didConnect {
                    lunaLog("luna: connection closed: %@", reason)
                } else {
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - connectStarted.uptimeNanoseconds) / 1_000_000
                    lunaLog("luna: %@ connect failed after %.1f ms: %@", mode, elapsed, reason)
                }
            }
            if let pinnedInterface, !didConnect {
                // The user chose this interface; failing is better than
                // silently using another one.
                self.lastConnectError =
                    "Could not reach \(name) via \(InterfaceMonitor.label(for: pinnedInterface))"
                self.disconnect()
            } else if wiredOnly, !didConnect {
                lunaLog("luna: wired probe unsuccessful, retrying with default routing")
                self.attemptConnection(endpoint: fallback, fallback: fallback, name: name,
                                       wiredOnly: false, pinnedInterface: nil)
            } else {
                self.disconnect()
            }
        }
        conn.onMessage = { [weak self, weak conn] msg in
            guard let self, let conn, self.connection === conn else { return }
            if case .caps(let w, let h, let receiverName, _, _) = msg {
                lunaLog("luna: receiver %@ reports screen %dx%d", receiverName, w, h)
            }
        }
        conn.start()
    }

    private func handleConnected(name: String) {
        guard let connection else { return }
        let preset = preset
        let pixels = preset.displayPixels
        let stream = preset.streamSize

        guard virtualDisplay.create(
            pixelWidth: pixels.width,
            pixelHeight: pixels.height,
            hiDPI: preset.hiDPI,
            refreshHz: Double(fps),
            name: "Luna (\(name))"
        ) else {
            lunaLog("luna: virtual display creation failed")
            disconnect()
            return
        }

        connection.send(LunaWire.helloData(
            streamWidth: stream.width,
            streamHeight: stream.height,
            fps: fps,
            senderName: Host.current().localizedName ?? "Mac"
        ))
        startCapture(connection: connection, preset: preset)
    }

    private func startCapture(connection: SenderConnection, preset: DisplayPreset) {
        let encoder = CaptureEncoder(config: .init(
            displayID: virtualDisplay.displayID,
            streamWidth: preset.streamSize.width,
            streamHeight: preset.streamSize.height,
            fps: fps,
            bitrate: preset.bitrate
        ))
        self.encoder = encoder
        encoder.onPacket = { [weak connection] packet, tracePTS in
            connection?.send(packet, ptsMicros: tracePTS)
        }
        // About three average frames. Drop before encoding to preserve H.264 dependencies.
        let maxPendingBytes = preset.bitrate / 8 / fps * 3
        encoder.shouldDropFrame = { [weak connection] in
            guard let connection else { return true }
            return connection.pendingBytes > maxPendingBytes
        }
        encoder.onStarted = { [weak self, weak encoder] in
            DispatchQueue.main.async {
                guard let self, let encoder, self.encoder === encoder,
                      case .connecting(let name) = self.state else { return }
                self.preventSleep(true)
                self.state = .streaming(name)
            }
        }
        encoder.onError = { [weak self, weak encoder] message in
            DispatchQueue.main.async {
                // Ignore late errors from an encoder we already replaced.
                guard let self, let encoder, self.encoder === encoder else { return }
                lunaLog("luna: %@", message)
                self.disconnect()
            }
        }
        encoder.start()
    }

    func disconnect() {
        resolver?.cancel()
        resolver = nil
        currentInterfaceLabel = nil
        connection?.cancel()
        connection = nil
        encoder?.stop()
        encoder = nil
        virtualDisplay.destroy()
        preventSleep(false)
        if state != .idle { state = .idle }
    }

    private func preventSleep(_ prevent: Bool) {
        if prevent, sleepAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Luna is streaming a display" as CFString,
                &sleepAssertion
            )
        } else if !prevent, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }
}
