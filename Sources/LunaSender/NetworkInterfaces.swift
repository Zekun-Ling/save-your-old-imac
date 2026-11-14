import Foundation
import Network
import LunaProto

/// Combines default-path interfaces with links discovered through Bonjour.
/// A direct Thunderbolt link can be absent from the default internet path.
final class InterfaceMonitor {
    static let shared = InterfaceMonitor()
    private let monitor = NWPathMonitor()
    private var started = false

    private var pathInterfaces: [NWInterface] = []
    private var discoveredInterfaces: [NWInterface] = []

    /// Main-queue snapshot for the menu and exact interface pinning.
    private(set) var interfaces: [NWInterface] = []
    var onChange: (() -> Void)?

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.availableInterfaces
            DispatchQueue.main.async {
                guard let self else { return }
                self.pathInterfaces = available
                self.rebuildInterfaces()
            }
        }
        monitor.start(queue: DispatchQueue(label: "luna.ifmonitor"))
    }

    /// Replace the complete Bonjour snapshot on the main queue, including
    /// removals; do not retain an interface just because it appeared once.
    func updateDiscoveredInterfaces(_ interfaces: [NWInterface]) {
        discoveredInterfaces = interfaces
        rebuildInterfaces()
    }

    private func rebuildInterfaces() {
        var byIndex: [Int: NWInterface] = [:]
        for interface in pathInterfaces + discoveredInterfaces {
            switch interface.type {
            case .wifi, .wiredEthernet:
                break
            case .other where interface.name.hasPrefix("bridge") || interface.name.hasPrefix("en"):
                break
            default:
                continue
            }
            byIndex[interface.index] = interface
        }
        let updated = byIndex.values.sorted { $0.index < $1.index }
        guard updated != interfaces else { return }
        interfaces = updated
        onChange?()
    }

    func interface(named name: String) -> NWInterface? {
        interfaces.first { $0.name == name }
    }

    static func label(for interface: NWInterface) -> String {
        NetInfo.label(bsd: interface.name, type: interface.type)
    }
}
