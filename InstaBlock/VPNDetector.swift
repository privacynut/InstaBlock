//
//  VPNDetector.swift
//  InstaBlock
//
//  Detects whether some VPN other than ours is *actually carrying traffic*.
//  iOS allows one active VPN, so if one is present, starting our tunnel would
//  evict it — the app must wait instead.
//
//  A VPN that is merely selected in Settings (or recently disconnected) can
//  leave its utun interface configured with an address, so an interface
//  listing alone over-detects. Two stronger signals are used:
//    1. the default network path runs through a VPN interface that isn't ours;
//    2. a VPN interface is up with a routable address AND the system currently
//       has network settings scoped to it (only connected VPNs get those).
//

import Foundation
import Network
import CFNetwork

enum VPNDetector {
    /// Our tunnel's own addresses; a utun carrying one of them is us.
    private static let ownAddresses: Set<String> = ["198.18.0.2", "fd1b:1b1b::2"]
    private static let vpnPrefixes = ["utun", "ipsec", "ppp", "tap", "tun"]

    static func otherVPNActive() async -> Bool {
        let interfaces = scanInterfaces()
        let ours = Set(interfaces.filter { $0.value.ours }.map { $0.key })

        // 1. Is the default path going through a VPN interface that isn't ours?
        let path = await currentPath()
        if path.status == .satisfied,
           path.availableInterfaces.contains(where: { $0.type == .other && !ours.contains($0.name) }) {
            return true
        }

        // 2. Up + routable + present in the live system network configuration.
        let scoped = scopedInterfaceNames()
        return interfaces.contains { name, info in
            info.up && info.routable && !info.ours && scoped.contains(name)
        }
    }

    private struct Info { var up = false, ours = false, routable = false }

    private static func scanInterfaces() -> [String: Info] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [:] }
        defer { freeifaddrs(list) }
        var result: [String: Info] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let name = String(cString: ifa.pointee.ifa_name)
            guard vpnPrefixes.contains(where: { name.hasPrefix($0) }), let addr = ifa.pointee.ifa_addr else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let flags = Int32(ifa.pointee.ifa_flags)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host).components(separatedBy: "%")[0]
            let routable = !ip.hasPrefix("fe80") && !ip.hasPrefix("169.254") && ip != "::1" && ip != "127.0.0.1"
            var info = result[name] ?? Info()
            info.up = info.up || ((flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0)
            info.ours = info.ours || ownAddresses.contains(ip)
            info.routable = info.routable || routable
            result[name] = info
        }
        return result
    }

    /// Interfaces the system currently has DNS/proxy settings scoped to —
    /// populated for connected VPNs, absent for merely-selected ones.
    private static func scopedInterfaceNames() -> Set<String> {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
              let scoped = settings["__SCOPED__"] as? [String: Any] else { return [] }
        return Set(scoped.keys)
    }

    private static func currentPath() async -> NWPath {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let lock = NSLock()
            var resumed = false
            monitor.pathUpdateHandler = { path in
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: path)
                monitor.cancel()
            }
            monitor.start(queue: DispatchQueue.global(qos: .utility))
        }
    }
}
