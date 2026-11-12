import Foundation
import Network
import SystemConfiguration
import Darwin

/// Names a BSD interface the way System Settings does ("Wi-Fi",
/// "Thunderbolt Bridge", "Ethernet"), so both apps can tell the user which
/// link a connection actually uses.
public enum NetInfo {
    /// Match the address this connection actually uses to a local interface.
    /// A path may list multiple candidate interfaces, so don't guess their order.
    public static func interface(for path: NWPath?) -> NWInterface? {
        guard let path, case .hostPort(let host, _) = path.localEndpoint else { return nil }
        let localAddress: Data
        let family: Int32
        switch host {
        case .ipv4(let address):
            if let interface = address.interface { return interface }
            localAddress = address.rawValue
            family = AF_INET
        case .ipv6(let address):
            if let interface = address.interface { return interface }
            if let ipv4 = address.asIPv4 {
                localAddress = ipv4.rawValue
                family = AF_INET
            } else {
                localAddress = ipv6Bytes(address)
                family = AF_INET6
            }
        default:
            return nil
        }

        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let addresses else { return nil }
        defer { freeifaddrs(addresses) }
        var names = Set<String>()
        for entry in sequence(first: addresses, next: { $0.pointee.ifa_next }) {
            guard let socketAddress = entry.pointee.ifa_addr,
                  Int32(socketAddress.pointee.sa_family) == family else { continue }
            let bytes: Data
            if family == AF_INET {
                let address = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                bytes = withUnsafeBytes(of: address) { Data($0) }
            } else {
                let address = socketAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                guard let ip = withUnsafeBytes(of: address, { IPv6Address(Data($0)) }) else { continue }
                bytes = ipv6Bytes(ip)
            }
            if bytes == localAddress { names.insert(String(cString: entry.pointee.ifa_name)) }
        }
        let matches = path.availableInterfaces.filter { names.contains($0.name) }
        return matches.count == 1 ? matches.first : nil
    }

    private static func ipv6Bytes(_ address: IPv6Address) -> Data {
        var bytes = address.rawValue
        if address.isLinkLocal {
            // Darwin sockaddr values may embed the link-local zone in these bytes.
            bytes[2] = 0
            bytes[3] = 0
        }
        return bytes
    }

    public static func displayName(bsd: String, type: NWInterface.InterfaceType?) -> String {
        for item in SCNetworkInterfaceCopyAll() as NSArray {
            let sc = item as! SCNetworkInterface
            if let name = SCNetworkInterfaceGetBSDName(sc) as String?, name == bsd,
               let display = SCNetworkInterfaceGetLocalizedDisplayName(sc) as String? {
                return display
            }
        }
        // SCNetworkInterfaceCopyAll misses virtual interfaces like bridges.
        if bsd == "bridge0" { return "Thunderbolt Bridge" }
        if bsd.hasPrefix("bridge") { return "Network Bridge" }
        switch type {
        case .wifi: return "Wi-Fi"
        case .wiredEthernet: return "Ethernet"
        case .loopback: return "Loopback"
        default: return "Network"
        }
    }

    /// "Thunderbolt Bridge (bridge0)" — for menus, status lines and logs.
    public static func label(bsd: String, type: NWInterface.InterfaceType?) -> String {
        "\(displayName(bsd: bsd, type: type)) (\(bsd))"
    }
}
