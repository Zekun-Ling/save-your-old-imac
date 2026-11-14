import Foundation
import Network
import dnssd
import LunaProto

/// Resolves a Bonjour service to its hostname + port (SRV record).
/// Needed because NWConnection stalls when a service endpoint is combined
/// with prohibitedInterfaceTypes, while a plain host:port dial honors the
/// prohibition and happily uses a Thunderbolt bridge / Ethernet link.
final class ServiceResolver {
    typealias Result = (host: String, port: UInt16, interfaceIndex: UInt32)

    private let queue = DispatchQueue(label: "luna.resolver")
    private var ref: DNSServiceRef?
    private let completion: (ServiceResolver, Result?) -> Void
    private var finished = false

    /// completion fires exactly once, on the main queue; nil on failure.
    init(completion: @escaping (ServiceResolver, Result?) -> Void) {
        self.completion = completion
    }

    func resolve(name: String, type: String, domain: String, interfaceIndex: UInt32, timeout: TimeInterval = 2.0) {
        queue.async {
            guard !self.finished else { return }
            let context = Unmanaged.passRetained(self).toOpaque()
            var ref: DNSServiceRef?
            let error = DNSServiceResolve(
                &ref, 0, interfaceIndex, name, type, domain,
                { _, _, index, error, _, host, port, _, _, context in
                    guard let context else { return }
                    let resolver = Unmanaged<ServiceResolver>.fromOpaque(context).takeUnretainedValue()
                    let result: Result?
                    if error == kDNSServiceErr_NoError, let host {
                        result = (String(cString: host), UInt16(bigEndian: port), index)
                    } else {
                        result = nil
                    }
                    resolver.queue.async { resolver.finish(result) }
                },
                context
            )
            guard error == kDNSServiceErr_NoError, let ref else {
                Unmanaged<ServiceResolver>.fromOpaque(context).release()
                self.finish(nil)
                return
            }
            self.ref = ref
            guard DNSServiceSetDispatchQueue(ref, self.queue) == kDNSServiceErr_NoError else {
                self.finish(nil)
                return
            }
            self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(nil) }
        }
    }

    func cancel() {
        queue.async { self.finish(nil) }
    }

    private func finish(_ result: Result?) {
        guard !finished else { return }
        finished = true
        if let ref {
            DNSServiceRefDeallocate(ref)
            self.ref = nil
            Unmanaged.passUnretained(self).release()  // balances passRetained
        }
        DispatchQueue.main.async { self.completion(self, result) }
    }
}

/// Browses Bonjour for LunaReceiver instances on the local network.
final class ReceiverBrowser {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "luna.browser")

    /// Called on the main queue whenever the result set changes.
    var onResults: (([NWBrowser.Result]) -> Void)?

    func start() {
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: LunaWire.serviceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let sorted = results.sorted { a, b in
                Self.name(of: a) < Self.name(of: b)
            }
            DispatchQueue.main.async { self?.onResults?(sorted) }
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                lunaLog("luna: bonjour browse failed: %@", error.localizedDescription)
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    static func name(of result: NWBrowser.Result) -> String {
        if case .service(let name, _, _, _) = result.endpoint {
            return name
        }
        return "\(result.endpoint)"
    }
}

/// One outbound TCP connection to a receiver, with send backpressure tracking.
final class SenderConnection {
    private let queue = DispatchQueue(label: "luna.sender.net")
    private let connection: NWConnection
    private let parser = LunaMessageParser()
    private let pendingLock = NSLock()
    private var pending = 0

    /// Bytes handed to the connection but not yet processed by the transport.
    var pendingBytes: Int {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pending
    }

    var onReady: ((NWInterface?) -> Void)?  // main queue
    var onClosed: ((String?) -> Void)?  // main queue
    var onMessage: ((LunaMessage) -> Void)?  // main queue

    private var closed = false
    private let wiredOnly: Bool
    private let pinned: Bool
    private var becameReady = false  // touched only on `queue`
    private var receivedCaps = false  // touched only on `queue`
    private var transportSample: NWConnection.PendingDataTransferReport?  // only on `queue`

    /// wiredOnly: refuse Wi-Fi paths and give up quickly, so the caller can
    /// probe for a Thunderbolt bridge / Ethernet link before falling back.
    /// requiredInterface: pin the connection to that interface (no fallback).
    init(endpoint: NWEndpoint, wiredOnly: Bool = false, requiredInterface: NWInterface? = nil) {
        self.wiredOnly = wiredOnly
        self.pinned = requiredInterface != nil
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        if wiredOnly {
            params.prohibitedInterfaceTypes = [.wifi, .cellular]
        }
        if let requiredInterface {
            params.requiredInterface = requiredInterface
        }
        connection = NWConnection(to: endpoint, using: params)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !self.becameReady else { return }
                self.becameReady = true
                let interface = NetInfo.interface(for: self.connection.currentPath)
                DispatchQueue.main.async { self.onReady?(interface) }
                if LatencyTrace.enabled { self.sampleTransportRTT() }
            case .waiting(let error):
                // Normal connects ride out .waiting; the wired probe and a
                // pinned interface treat "no usable path" as an immediate miss.
                if self.wiredOnly || self.pinned {
                    self.close(reason: "no usable path (\(error.localizedDescription))")
                    self.connection.cancel()
                }
            case .failed(let error):
                self.transportSample = nil
                self.close(reason: error.localizedDescription)
            case .cancelled:
                self.transportSample = nil
                self.close(reason: nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveLoop()
        let probeTimeout: TimeInterval? = wiredOnly ? 2.5 : (pinned ? 5.0 : nil)
        if let probeTimeout {
            queue.asyncAfter(deadline: .now() + probeTimeout) { [weak self] in
                guard let self, !self.becameReady else { return }
                self.close(reason: self.wiredOnly
                    ? "wired probe timed out" : "connect timed out on the pinned interface")
                self.connection.cancel()
            }
        }
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let messages = self.parser.feed(data)
                if self.parser.corrupted {
                    self.close(reason: "stream out of sync (oversized frame)")
                    self.connection.cancel()
                    return
                }
                // Only one caps message is used by the sender. Do not let a
                // peer queue arbitrary messages onto the main thread.
                if !self.receivedCaps, let caps = messages.first(where: {
                    if case .caps = $0 { return true }
                    return false
                }) {
                    self.receivedCaps = true
                    DispatchQueue.main.async { self.onMessage?(caps) }
                }
            }
            if isComplete || error != nil {
                self.close(reason: error?.localizedDescription ?? "receiver disconnected")
                self.connection.cancel()
                return
            }
            self.receiveLoop()
        }
    }

    func send(_ data: Data, ptsMicros: Int64? = nil) {
        pendingLock.lock()
        pending += data.count
        pendingLock.unlock()
        if let ptsMicros { LatencyTrace.mark(.sent, ptsMicros: ptsMicros) }
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.pendingLock.lock()
            self.pending -= data.count
            self.pendingLock.unlock()
        })
    }

    func cancel() {
        connection.cancel()
    }

    private func sampleTransportRTT() {
        guard case .ready = connection.state else { return }
        transportSample = connection.startDataTransferReport()
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, case .ready = self.connection.state,
                  let sample = self.transportSample else { return }
            self.transportSample = nil
            sample.collect(queue: self.queue) { [weak self] report in
                guard let self, case .ready = self.connection.state else { return }
                for path in report.pathReports where path.sentApplicationByteCount > 0 {
                    let interface = path.interface
                    lunaLog("luna: TCP RTT via %@ (type %@): smoothed %.2f ms, minimum %.2f ms",
                            NetInfo.label(bsd: interface.name, type: interface.type), String(describing: interface.type),
                            path.transportSmoothedRTT * 1_000, path.transportMinimumRTT * 1_000)
                }
                self.sampleTransportRTT()
            }
        }
    }

    private func close(reason: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            self.closed = true
            self.onClosed?(reason)
        }
    }
}
