import Foundation
import CoreGraphics
import Network
import LunaProto

/// Advertises this Mac via Bonjour and accepts one sender connection.
final class ReceiverServer {
    private let queue = DispatchQueue(label: "luna.receiver.net")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var connectionInterfaceLabel: String?
    private var parser = LunaMessageParser()
    private var deliveringBatch = false
    private var receivedFirstFrame = false

    // All callbacks fire on the main queue.
    var onListening: ((String) -> Void)?
    /// Returns true when the message submitted a decodable video sample.
    var onMessage: ((LunaMessage, String?) -> Bool)?
    var onDisconnected: (() -> Void)?

    /// Fixed port so the receiver's address survives relaunches; falls back
    /// to an ephemeral port if something else already holds it.
    static let preferredPort: UInt16 = 52525

    func start(loopbackOnly: Bool = false) {
        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }
            self.start(fixedPort: Self.preferredPort, loopbackOnly: loopbackOnly)
        }
    }

    private func start(fixedPort: UInt16?, loopbackOnly: Bool) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        // Notice a vanished sender (crash, Wi-Fi drop) in ~11 s instead of the
        // OS default of many minutes; until then accept() refuses a new sender.
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)

        let listener: NWListener
        do {
            if let fixedPort, let port = NWEndpoint.Port(rawValue: fixedPort) {
                if loopbackOnly {
                    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
                    params.requiredInterfaceType = .loopback
                    listener = try NWListener(using: params)
                } else {
                    listener = try NWListener(using: params, on: port)
                }
            } else {
                listener = try NWListener(using: params)
            }
        } catch {
            if let fixedPort, !loopbackOnly {
                lunaLog("luna: port %d unavailable (%@), using an ephemeral port",
                      Int(fixedPort), error.localizedDescription)
                start(fixedPort: nil, loopbackOnly: false)
            } else {
                lunaLog("luna: could not create listener: %@", error.localizedDescription)
            }
            return
        }
        if !loopbackOnly {
            listener.service = NWListener.Service(
                name: Host.current().localizedName ?? "Mac",
                type: LunaWire.serviceType
            )
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            if case .ready = state {
                let port = listener.port.map { String($0.rawValue) } ?? "?"
                let host = loopbackOnly ? "127.0.0.1" : ProcessInfo.processInfo.hostName
                let address = "\(host):\(port)"
                lunaLog("luna: listening at %@", address)
                DispatchQueue.main.async {
                    self.onListening?(address)
                }
            }
            if case .failed(let error) = state {
                lunaLog("luna: listener failed: %@", error.localizedDescription)
                self.listener = nil
                listener.cancel()
                if fixedPort != nil, !loopbackOnly {
                    self.start(fixedPort: nil, loopbackOnly: false)
                }
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] conn in
            guard let self, let listener, self.listener === listener else {
                conn.cancel()
                return
            }
            self.accept(conn)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func accept(_ conn: NWConnection) {
        guard connection == nil, !deliveringBatch else {
            conn.cancel()
            return
        }
        connection = conn
        parser = LunaMessageParser()
        receivedFirstFrame = false

        // TCP keepalive detects dead sockets, but a silent live peer would
        // otherwise hold the only slot indefinitely.
        queue.asyncAfter(deadline: .now() + 12) { [weak self, weak conn] in
            guard let self, let conn, self.connection === conn, !self.receivedFirstFrame else { return }
            lunaLog("luna: no usable video within 12 seconds, dropping the sender")
            self.dropConnection(conn)
        }

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn, self.connection === conn else { return }
            switch state {
            case .ready:
                self.connectionInterfaceLabel = NetInfo.interface(for: conn.currentPath).map {
                    NetInfo.label(bsd: $0.name, type: $0.type)
                }
                lunaLog("luna: sender connected via %@", self.connectionInterfaceLabel ?? "unknown interface")
                let screen = ReceiverScreenInfo.current()
                conn.send(
                    content: LunaWire.capsData(
                        screenWidth: screen.width,
                        screenHeight: screen.height,
                        name: Host.current().localizedName ?? "Mac",
                        // This build has no reverse camera/mic channel.
                        hasCamera: false,
                        hasMic: false
                    ),
                    completion: .contentProcessed { _ in }
                )
                self.receiveLoop(conn)
            case .failed, .cancelled:
                self.dropConnection(conn)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self, weak conn] data, _, isComplete, error in
            guard let self, let conn, self.connection === conn else { return }
            let messages = data.map { self.parser.feed($0) } ?? []
            if self.parser.corrupted {
                lunaLog("luna: stream out of sync (oversized frame), dropping the sender")
                self.dropConnection(conn)
                return
            }
            let ended = isComplete || error != nil
            guard !messages.isEmpty else {
                self.finishReceive(conn, ended: ended)
                return
            }
            // Only one batch can wait for the UI. Pause reads while it is
            // busy so TCP can apply backpressure instead of retaining frames.
            self.deliveringBatch = true
            let label = self.connectionInterfaceLabel
            for case .frame(let pts, _, _) in messages {
                LatencyTrace.mark(.received, ptsMicros: pts)
            }
            DispatchQueue.main.async {
                var receivedFrame = false
                for msg in messages {
                    if self.onMessage?(msg, label) == true { receivedFrame = true }
                }
                let batchReceivedFrame = receivedFrame
                self.queue.async {
                    self.deliveringBatch = false
                    self.finishReceive(conn, ended: ended, receivedFrame: batchReceivedFrame)
                }
            }
        }
    }

    private func finishReceive(_ conn: NWConnection, ended: Bool, receivedFrame: Bool = false) {
        guard connection === conn else { return }
        if receivedFrame { receivedFirstFrame = true }
        if ended {
            dropConnection(conn)
        } else {
            receiveLoop(conn)
        }
    }

    private func dropConnection(_ conn: NWConnection) {
        guard connection === conn else { return }
        connection = nil
        connectionInterfaceLabel = nil
        parser = LunaMessageParser()
        conn.cancel()
        DispatchQueue.main.async { self.onDisconnected?() }
    }
}

enum ReceiverScreenInfo {
    static func current() -> (width: Int, height: Int) {
        let id = CGMainDisplayID()
        return (Int(CGDisplayPixelsWide(id)), Int(CGDisplayPixelsHigh(id)))
    }
}
