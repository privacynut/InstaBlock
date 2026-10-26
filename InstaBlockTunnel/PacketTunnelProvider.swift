//
//  PacketTunnelProvider.swift
//  InstaBlockTunnel
//
//  Learn-and-shape filter for Instagram's media CDNs.
//
//  The tunnel claims no default route. Split-DNS (NEDNSSettings.matchDomains)
//  sends ONLY queries for the blocked domains to a fake resolver inside the
//  tunnel. Each query is forwarded to the network's real resolver; the
//  answered IPs are LEARNED and routed into the tunnel (/32, /128) before the
//  answer is handed back, so the client can never reach a CDN address the
//  tunnel doesn't own. Traffic arriving for those addresses is relayed —
//  UDP (QUIC) through a per-host token bucket capped at the configured rate,
//  TCP dropped. Photos are small and survive the trickle; video stalls.
//
//  Breaks are owned by the extension: the app sends "break:<unix-time>", the
//  learned routes are withdrawn so traffic bypasses the tunnel, and an
//  in-process timer restores them when the break ends. The VPN never
//  disconnects, so re-blocking doesn't depend on the app running.
//

import Foundation
import Network
import NetworkExtension
import ResolvShim
import UserNotifications
import os

class PacketTunnelProvider: NEPacketTunnelProvider {

    /// Instagram (Meta media CDNs, incl. ISP-hosted *.fna.fbcdn.net caches):
    /// photos and videos share these hosts, so traffic is THROTTLED — photos
    /// survive the trickle, video stalls.
    static let throttleDomains = [
        "fbcdn.net",
        "cdninstagram.com",
    ]

    /// TikTok (ByteDance CDNs): all video, nothing worth preserving, and its
    /// short low-bitrate clips slip through a throttle — so traffic to these
    /// hosts is DROPPED outright. Note TikTok's Fastly nodes serve the API
    /// from the same IPs as the video CDN, so the feed stops loading too.
    static let dropDomains = [
        "tiktokcdn.com",
        "tiktokcdn-us.com",
        "tiktokcdn-eu.com",
        "ibytedtos.com",
        "bytefcdn-oversea.com",
        "byteicdn.com",
        "bytedance.map.fastly.net",   // TikTok resolves this CNAME target directly
    ]

    /// Everything whose lookups are intercepted (split-DNS). Suffix match
    /// covers subdomains. Keep in sync with TunnelBlocker.blockedDomains.
    static let blockedDomains = throttleDomains + dropDomains

    // RFC 2544 benchmark range — never routable on the real internet.
    private static let dnsServerIP = "198.18.0.53"
    private static let dnsServerBytes: [UInt8] = [198, 18, 0, 53]
    private static let tunnelLocalIP = "198.18.0.2"
    private static let tunnelRemoteIP = "198.18.0.1"
    private static let tunnelLocalIPv6 = "fd1b:1b1b::2"
    private static let fallbackUpstreams = ["1.1.1.1", "8.8.8.8"]
    private static let maxLearned = 512

    // Shaping parameters
    static let defaultRateKbps = 150
    private static let burstBytes = 384 * 1024
    private static let maxQueuedPackets = 256
    private static let flowIdleTimeout: TimeInterval = 60

    private let log = Logger(subsystem: "com.helpon.InstaBlock.tunnel", category: "provider")
    private let queue = DispatchQueue(label: "com.helpon.InstaBlock.tunnel.state")
    private let defaults = UserDefaults.standard

    private var learnedV4 = Set<String>()   // throttled hosts
    private var learnedV6 = Set<String>()
    private var dropV4 = Set<String>()      // dropped hosts
    private var dropV6 = Set<String>()
    private var upstreams: [String] = []
    private var dnsConnections: [ObjectIdentifier: NWConnection] = [:]

    private var rateKbps = PacketTunnelProvider.defaultRateKbps
    private var flows: [String: UDPFlow] = [:]
    private var shapers: [String: Shaper] = [:]
    private var drainTimer: DispatchSourceTimer?
    private var sweepTimer: DispatchSourceTimer?

    private var pathMonitor: NWPathMonitor?
    private var lastPhysicalInterface: NWInterface.InterfaceType?

    private var breakEnd: Date?
    private var breakTimer: DispatchSourceTimer?
    private var isOnBreak: Bool { breakEnd.map { $0 > Date() } ?? false }

    final class UDPFlow {
        let connection: NWConnection
        let family: Int32
        let clientIP: [UInt8], serverIP: [UInt8]
        let clientPort: UInt16, serverPort: UInt16
        let serverKey: String
        var ready = false
        var pending: [Data] = []
        var lastActivity = Date()

        init(connection: NWConnection, family: Int32, clientIP: [UInt8], serverIP: [UInt8],
             clientPort: UInt16, serverPort: UInt16, serverKey: String) {
            self.connection = connection; self.family = family
            self.clientIP = clientIP; self.serverIP = serverIP
            self.clientPort = clientPort; self.serverPort = serverPort
            self.serverKey = serverKey
        }
    }

    final class Shaper {
        var tokens: Double
        var lastRefill = Date()
        var queue: [(Data, Int32)] = []
        init(tokens: Double) { self.tokens = tokens }
    }

    // MARK: - Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        learnedV4 = Set(defaults.stringArray(forKey: "learnedV4") ?? [])
        learnedV6 = Set(defaults.stringArray(forKey: "learnedV6") ?? [])
        dropV4 = Set(defaults.stringArray(forKey: "dropV4") ?? [])
        dropV6 = Set(defaults.stringArray(forKey: "dropV6") ?? [])
        upstreams = Self.systemResolvers()
        if upstreams.isEmpty { upstreams = Self.fallbackUpstreams }

        let config = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        if let configured = config?["rateKbps"] as? Int {
            rateKbps = configured
        } else if defaults.object(forKey: "rateKbps") != nil {
            rateKbps = defaults.integer(forKey: "rateKbps")
        }
        // A break survives a tunnel restart (on-demand reconnects, reboots).
        if let end = defaults.object(forKey: "breakEnd") as? Date, end > Date() {
            breakEnd = end
            scheduleBreakEnd()
        }
        log.notice("starting; learned v4=\(self.learnedV4.count) v6=\(self.learnedV6.count) rate=\(self.rateKbps)kbps break=\(self.isOnBreak)")

        setTunnelNetworkSettings(makeSettings()) { error in
            if let error {
                completionHandler(error)
                return
            }
            self.startSweepTimer()
            self.startPathMonitor()
            self.readPackets()
            completionHandler(nil)
            if self.defaults.bool(forKey: "pausedNotified") {
                self.defaults.removeObject(forKey: "pausedNotified")
                let center = UNUserNotificationCenter.current()
                // Clean up any reminder left over from an earlier build.
                center.removePendingNotificationRequests(withIdentifiers: ["vpn-paused-reminder"])
                center.removeDeliveredNotifications(withIdentifiers: ["vpn-paused", "vpn-paused-reminder"])
                Self.notify(id: "vpn-resumed", title: "InstaBlock is back on",
                            body: "Instagram and TikTok videos are blocked again.", category: "VPN_RESUMED") {}
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.sync {
            drainTimer?.cancel(); drainTimer = nil
            sweepTimer?.cancel(); sweepTimer = nil
            breakTimer?.cancel(); breakTimer = nil
            pathMonitor?.cancel(); pathMonitor = nil
            flows.values.forEach { $0.connection.cancel() }
            flows.removeAll()
            shapers.removeAll()
        }
        // Tell the user when the block goes away for a reason on-demand won't
        // fix by itself (another VPN took over, or it was switched off), and
        // remember it so the next start can announce "back on".
        let body: String?
        switch reason {
        case .superceded, .userSwitch:
            body = "Another VPN took over. Videos are NOT blocked until it disconnects."
        case .userInitiated, .configurationDisabled, .providerDisabled:
            body = "InstaBlock was turned off. Videos are NOT blocked."
        default:
            body = nil
        }
        log.notice("stopping: reason \(reason.rawValue)")
        guard let body else { completionHandler(); return }
        defaults.set(true, forKey: "pausedNotified")
        Self.notify(id: "vpn-paused", title: "InstaBlock is off", body: body, category: "VPN_PAUSED") {
            completionHandler()
        }
    }

    /// Post a local notification from the extension (uses the host app's permission).
    private static func notify(id: String, title: String, body: String, category: String, completion: @escaping () -> Void) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in completion() }
    }

    /// App messages: "break:<unix-time>" starts/extends a break until then,
    /// "resume" ends it now, "rate:<kbps>" changes the cap.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let message = String(decoding: messageData, as: UTF8.self)
        queue.async {
            if message.hasPrefix("break:"), let ts = TimeInterval(message.dropFirst(6)) {
                self.startBreak(until: Date(timeIntervalSince1970: ts))
            } else if message == "resume" {
                self.endBreak()
            } else if message.hasPrefix("rate:"), let kbps = Int(message.dropFirst(5)) {
                self.rateKbps = max(0, kbps)
                self.defaults.set(self.rateKbps, forKey: "rateKbps")
            }
            completionHandler?(Data("ok".utf8))
        }
    }

    // MARK: - Breaks (owned by the extension)

    private func startBreak(until end: Date) {
        breakEnd = end
        defaults.set(end, forKey: "breakEnd")
        log.notice("break until \(end)")
        scheduleBreakEnd()
        // Withdraw the CDN routes so media flows directly; drop relay state.
        flows.values.forEach { $0.connection.cancel() }
        flows.removeAll()
        shapers.removeAll()
        applySettings()
    }

    private func endBreak() {
        guard breakEnd != nil else { return }
        breakEnd = nil
        defaults.removeObject(forKey: "breakEnd")
        breakTimer?.cancel(); breakTimer = nil
        log.notice("break over — restoring routes")
        applySettings()
    }

    private func scheduleBreakEnd() {
        breakTimer?.cancel()
        guard let end = breakEnd else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(0, end.timeIntervalSinceNow))
        timer.setEventHandler { [weak self] in self?.endBreak() }
        timer.resume()
        breakTimer = timer
    }

    // MARK: - Tunnel settings

    private func makeSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: Self.tunnelRemoteIP)
        let blocking = !isOnBreak

        let ipv4 = NEIPv4Settings(addresses: [Self.tunnelLocalIP], subnetMasks: ["255.255.255.255"])
        var v4Routes = [NEIPv4Route(destinationAddress: Self.dnsServerIP, subnetMask: "255.255.255.255")]
        if blocking {
            v4Routes += learnedV4.union(dropV4).sorted().map { NEIPv4Route(destinationAddress: $0, subnetMask: "255.255.255.255") }
        }
        ipv4.includedRoutes = v4Routes
        settings.ipv4Settings = ipv4

        let ipv6 = NEIPv6Settings(addresses: [Self.tunnelLocalIPv6], networkPrefixLengths: [64])
        ipv6.includedRoutes = blocking
            ? learnedV6.union(dropV6).sorted().map { NEIPv6Route(destinationAddress: $0, networkPrefixLength: 128) }
            : []
        settings.ipv6Settings = ipv6

        let dns = NEDNSSettings(servers: [Self.dnsServerIP])
        dns.matchDomains = Self.blockedDomains
        dns.matchDomainsNoSearch = true
        settings.dnsSettings = dns
        return settings
    }

    private func applySettings(completion: (() -> Void)? = nil) {
        setTunnelNetworkSettings(makeSettings()) { error in
            if let error { self.log.error("settings update failed: \(error.localizedDescription)") }
            self.queue.async { completion?() }
        }
    }

    // MARK: - Packet loop

    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            self.queue.async {
                for packet in packets { self.handle(packet) }
            }
            self.readPackets()
        }
    }

    private func handle(_ packet: Data) {
        guard let parsed = Self.parse(packet) else { return }
        switch parsed {
        case .udp(let udp):
            if udp.family == AF_INET, udp.dst == Self.dnsServerBytes, udp.dstPort == 53 {
                resolve(udp)
            } else if isDropped(udp.dst, family: udp.family) {
                return
            } else if rateKbps > 0 {
                relay(udp)
            }
        case .tcp, .other:
            break
        }
    }

    private func isDropped(_ ip: [UInt8], family: Int32) -> Bool {
        let key = Self.ipString(ip, family: family)
        return family == AF_INET ? dropV4.contains(key) : dropV6.contains(key)
    }

    // MARK: - DNS: forward, learn, route, then answer

    private func resolve(_ query: UDPPacket, attempt: Int = 0) {
        guard attempt < upstreams.count else {
            deliverDNS(Self.nxdomain(for: query.payload), to: query)
            return
        }
        let params = NWParameters.udp
        params.prohibitedInterfaceTypes = [.other, .loopback]
        let connection = NWConnection(host: NWEndpoint.Host(upstreams[attempt]), port: 53, using: params)
        let id = ObjectIdentifier(connection)
        dnsConnections[id] = connection

        var finished = false
        let finish: (Data?) -> Void = { response in
            self.queue.async {
                guard !finished else { return }
                finished = true
                connection.cancel()
                self.dnsConnections[id] = nil
                guard let response else {
                    self.resolve(query, attempt: attempt + 1)
                    return
                }
                // Route the answered addresses before the client learns them.
                let name = Self.questionName(in: query.payload) ?? ""
                if self.learn(from: response, name: name), !self.isOnBreak {
                    self.applySettings { self.deliverDNS(response, to: query) }
                } else {
                    self.deliverDNS(response, to: query)
                }
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: query.payload, completion: .contentProcessed { error in
                    if error != nil { finish(nil) }
                })
                connection.receiveMessage { data, _, _, error in
                    finish(error == nil ? data : nil)
                }
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 4) { finish(nil) }
    }

    private func deliverDNS(_ answer: Data, to query: UDPPacket) {
        let packet = Self.buildUDPPacket(family: AF_INET, src: Self.dnsServerBytes, dst: query.src,
                                         srcPort: 53, dstPort: query.srcPort, payload: answer)
        packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)])
    }

    /// Turn a DNS query into an NXDOMAIN response (same ID and question).
    static func nxdomain(for query: Data) -> Data {
        var bytes = [UInt8](query)
        guard bytes.count >= 12 else { return query }
        bytes[2] = (bytes[2] & 0x01) | 0x80   // QR=1, keep RD
        bytes[3] = 0x83                        // RA=1, RCODE=NXDOMAIN
        return Data(bytes)
    }

    /// Returns true when new addresses were learned. The question name decides
    /// the policy: drop-domain answers are dropped, everything else throttled.
    private func learn(from response: Data, name: String) -> Bool {
        let (v4, v6) = Self.answerAddresses(in: response)
        let drop = Self.matches(name, any: Self.dropDomains)
        var changed = false
        if drop {
            for ip in v4 where !dropV4.contains(ip) && dropV4.count < Self.maxLearned { dropV4.insert(ip); changed = true }
            for ip in v6 where !dropV6.contains(ip) && dropV6.count < Self.maxLearned { dropV6.insert(ip); changed = true }
        } else {
            for ip in v4 where !learnedV4.contains(ip) && learnedV4.count < Self.maxLearned { learnedV4.insert(ip); changed = true }
            for ip in v6 where !learnedV6.contains(ip) && learnedV6.count < Self.maxLearned { learnedV6.insert(ip); changed = true }
        }
        if changed {
            log.notice("learned \(name) -> \(v4) \(v6) [\(drop ? "drop" : "throttle")]")
            defaults.set(Array(learnedV4), forKey: "learnedV4")
            defaults.set(Array(learnedV6), forKey: "learnedV6")
            defaults.set(Array(dropV4), forKey: "dropV4")
            defaults.set(Array(dropV6), forKey: "dropV6")
        }
        return changed
    }

    /// Suffix match on label boundaries, like NEDNSSettings.matchDomains.
    static func matches(_ name: String, any domains: [String]) -> Bool {
        let host = name.lowercased()
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The QNAME of the first question in a DNS query.
    static func questionName(in query: Data) -> String? {
        let b = [UInt8](query)
        guard b.count > 12 else { return nil }
        var pos = 12
        var labels: [String] = []
        while pos < b.count {
            let len = Int(b[pos])
            if len == 0 { break }
            guard len & 0xC0 == 0, pos + 1 + len <= b.count else { return nil }
            labels.append(String(decoding: b[(pos + 1)..<(pos + 1 + len)], as: UTF8.self))
            pos += 1 + len
        }
        return labels.isEmpty ? nil : labels.joined(separator: ".")
    }

    // MARK: - UDP relay with shaping

    private func relay(_ udp: UDPPacket) {
        let serverKey = Self.ipString(udp.dst, family: udp.family)
        let flowKey = "\(Self.ipString(udp.src, family: udp.family)):\(udp.srcPort)>\(serverKey):\(udp.dstPort)"

        let flow: UDPFlow
        if let existing = flows[flowKey] {
            flow = existing
        } else {
            guard let port = NWEndpoint.Port(rawValue: udp.dstPort) else { return }
            let params = NWParameters.udp
            // Never let the relay's own sockets ride the tunnel (route loop).
            params.prohibitedInterfaceTypes = [.other, .loopback]
            let connection = NWConnection(host: NWEndpoint.Host(serverKey), port: port, using: params)
            flow = UDPFlow(connection: connection, family: udp.family, clientIP: udp.src, serverIP: udp.dst,
                           clientPort: udp.srcPort, serverPort: udp.dstPort, serverKey: serverKey)
            flows[flowKey] = flow
            connection.stateUpdateHandler = { [weak self, weak flow] state in
                guard let self, let flow else { return }
                switch state {
                case .ready:
                    flow.ready = true
                    for datagram in flow.pending { self.send(datagram, on: flow) }
                    flow.pending.removeAll()
                    self.receiveLoop(flow, key: flowKey)
                case .failed, .cancelled:
                    self.flows[flowKey] = nil
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        flow.lastActivity = Date()
        if flow.ready {
            send(udp.payload, on: flow)
        } else if flow.pending.count < 32 {
            flow.pending.append(udp.payload)
        }
    }

    private func send(_ datagram: Data, on flow: UDPFlow) {
        flow.connection.send(content: datagram, completion: .contentProcessed { _ in })
    }

    private func receiveLoop(_ flow: UDPFlow, key: String) {
        flow.connection.receiveMessage { [weak self, weak flow] data, _, _, error in
            guard let self, let flow else { return }
            if let data {
                flow.lastActivity = Date()
                let packet = Self.buildUDPPacket(family: flow.family, src: flow.serverIP, dst: flow.clientIP,
                                                 srcPort: flow.serverPort, dstPort: flow.clientPort, payload: data)
                self.shapeAndDeliver(packet, family: flow.family, serverKey: flow.serverKey)
            }
            if error == nil {
                self.receiveLoop(flow, key: key)
            } else {
                self.flows[key] = nil
            }
        }
    }

    /// Downstream token bucket per CDN host; excess is queued (bounded) and
    /// released by the drain timer, overflow dropped.
    private func shapeAndDeliver(_ packet: Data, family: Int32, serverKey: String) {
        let shaper: Shaper
        if let existing = shapers[serverKey] {
            shaper = existing
        } else {
            shaper = Shaper(tokens: Double(Self.burstBytes))
            shapers[serverKey] = shaper
        }
        refill(shaper)
        if shaper.queue.isEmpty, shaper.tokens >= Double(packet.count) {
            shaper.tokens -= Double(packet.count)
            deliver(packet, family: family)
        } else if shaper.queue.count < Self.maxQueuedPackets {
            shaper.queue.append((packet, family))
            ensureDrainTimer()
        }
    }

    private func refill(_ shaper: Shaper) {
        let now = Date()
        let bytesPerSecond = Double(rateKbps) * 1000 / 8
        shaper.tokens = min(Double(Self.burstBytes), shaper.tokens + now.timeIntervalSince(shaper.lastRefill) * bytesPerSecond)
        shaper.lastRefill = now
    }

    private func deliver(_ packet: Data, family: Int32) {
        packetFlow.writePackets([packet], withProtocols: [NSNumber(value: family)])
    }

    private func ensureDrainTimer() {
        guard drainTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        drainTimer = timer
    }

    private func drain() {
        var anyQueued = false
        for shaper in shapers.values {
            refill(shaper)
            while let (packet, family) = shaper.queue.first, shaper.tokens >= Double(packet.count) {
                shaper.tokens -= Double(packet.count)
                shaper.queue.removeFirst()
                deliver(packet, family: family)
            }
            if !shaper.queue.isEmpty { anyQueued = true }
        }
        if !anyQueued {
            drainTimer?.cancel()
            drainTimer = nil
        }
    }

    // MARK: - Network path changes (Wi-Fi <-> cellular)

    /// The upstream resolvers and the relay's sockets belong to the physical
    /// network the tunnel started on. When the phone moves between Wi-Fi and
    /// cellular, refresh the resolvers (the old ones may be unreachable, and
    /// each dead one costs a timeout per lookup) and drop the relay flows so
    /// new ones are opened on the new path.
    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.queue.async { self.handlePathChange(path) }
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    private func handlePathChange(_ path: Network.NWPath) {
        // Ignore our own utun (.other); look at the physical interface.
        let physical = path.availableInterfaces.first { $0.type != .other }?.type
        guard path.status == .satisfied, let physical else { return }
        let changed = lastPhysicalInterface != nil && lastPhysicalInterface != physical
        lastPhysicalInterface = physical
        let fresh = Self.systemResolvers()
        if !fresh.isEmpty, fresh != upstreams {
            upstreams = fresh
            log.notice("path changed to \(String(describing: physical)); resolvers now \(fresh)")
        }
        if changed {
            flows.values.forEach { $0.connection.cancel() }
            flows.removeAll()
            shapers.removeAll()
        }
    }

    private func startSweepTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let cutoff = Date().addingTimeInterval(-Self.flowIdleTimeout)
            for (key, flow) in self.flows where flow.lastActivity < cutoff {
                flow.connection.cancel()
                self.flows[key] = nil
            }
        }
        timer.resume()
        sweepTimer = timer
    }

    // MARK: - Packet parsing / building

    struct UDPPacket {
        let family: Int32
        let src: [UInt8], dst: [UInt8]
        let srcPort: UInt16, dstPort: UInt16
        let payload: Data
    }

    enum Parsed {
        case udp(UDPPacket)
        case tcp
        case other
    }

    static func parse(_ packet: Data) -> Parsed? {
        let b = [UInt8](packet)
        guard b.count >= 20 else { return nil }
        let version = b[0] >> 4
        if version == 4 {
            let ihl = Int(b[0] & 0x0F) * 4
            guard b.count >= ihl + 8 else { return nil }
            let proto = b[9]
            if proto == 6 { return .tcp }
            guard proto == 17 else { return .other }
            let src = Array(b[12..<16]), dst = Array(b[16..<20])
            let srcPort = UInt16(b[ihl]) << 8 | UInt16(b[ihl + 1])
            let dstPort = UInt16(b[ihl + 2]) << 8 | UInt16(b[ihl + 3])
            return .udp(UDPPacket(family: AF_INET, src: src, dst: dst, srcPort: srcPort, dstPort: dstPort,
                                  payload: Data(b[(ihl + 8)...])))
        } else if version == 6 {
            guard b.count >= 48 else { return nil }
            let next = b[6]
            if next == 6 { return .tcp }
            guard next == 17 else { return .other }
            let src = Array(b[8..<24]), dst = Array(b[24..<40])
            let srcPort = UInt16(b[40]) << 8 | UInt16(b[41])
            let dstPort = UInt16(b[42]) << 8 | UInt16(b[43])
            return .udp(UDPPacket(family: AF_INET6, src: src, dst: dst, srcPort: srcPort, dstPort: dstPort,
                                  payload: Data(b[48...])))
        }
        return nil
    }

    static func buildUDPPacket(family: Int32, src: [UInt8], dst: [UInt8], srcPort: UInt16, dstPort: UInt16, payload: Data) -> Data {
        let udpLength = 8 + payload.count
        var udp: [UInt8] = [UInt8(srcPort >> 8), UInt8(srcPort & 0xFF), UInt8(dstPort >> 8), UInt8(dstPort & 0xFF),
                            UInt8(udpLength >> 8), UInt8(udpLength & 0xFF), 0, 0]
        udp += [UInt8](payload)

        if family == AF_INET {
            let total = 20 + udpLength
            var ip: [UInt8] = [0x45, 0, UInt8(total >> 8), UInt8(total & 0xFF),
                               0, 0, 0x40, 0,            // id 0, DF
                               64, 17, 0, 0]             // ttl, proto, checksum
            ip += src + dst
            let sum = checksum(ip)
            ip[10] = UInt8(sum >> 8); ip[11] = UInt8(sum & 0xFF)
            return Data(ip + udp)                        // UDP checksum optional over IPv4
        } else {
            var pseudo = src + dst
            pseudo += [UInt8(udpLength >> 24), UInt8((udpLength >> 16) & 0xFF), UInt8((udpLength >> 8) & 0xFF), UInt8(udpLength & 0xFF)]
            pseudo += [0, 0, 0, 17]
            var sum = checksum(pseudo + udp)
            if sum == 0 { sum = 0xFFFF }
            udp[6] = UInt8(sum >> 8); udp[7] = UInt8(sum & 0xFF)
            var ip: [UInt8] = [0x60, 0, 0, 0, UInt8(udpLength >> 8), UInt8(udpLength & 0xFF), 17, 64]
            ip += src + dst
            return Data(ip + udp)
        }
    }

    /// Internet checksum (RFC 1071).
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum & 0xFFFF)
    }

    static func ipString(_ bytes: [UInt8], family: Int32) -> String {
        if family == AF_INET { return bytes.map(String.init).joined(separator: ".") }
        var addr = in6_addr()
        withUnsafeMutableBytes(of: &addr) { $0.copyBytes(from: bytes) }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count)) != nil else { return "" }
        return String(cString: buf)
    }

    /// Extract A / AAAA rdata from the answer section of a DNS response.
    static func answerAddresses(in msg: Data) -> ([String], [String]) {
        let b = [UInt8](msg)
        guard b.count >= 12 else { return ([], []) }
        let qdcount = Int(b[4]) << 8 | Int(b[5])
        let ancount = Int(b[6]) << 8 | Int(b[7])
        var pos = 12

        func skipName() -> Bool {
            while pos < b.count {
                let len = Int(b[pos])
                if len == 0 { pos += 1; return true }
                if len & 0xC0 == 0xC0 { pos += 2; return true }
                pos += 1 + len
            }
            return false
        }

        for _ in 0..<qdcount {
            guard skipName(), pos + 4 <= b.count else { return ([], []) }
            pos += 4
        }
        var v4: [String] = [], v6: [String] = []
        for _ in 0..<ancount {
            guard skipName(), pos + 10 <= b.count else { break }
            let type = Int(b[pos]) << 8 | Int(b[pos + 1])
            let rdlen = Int(b[pos + 8]) << 8 | Int(b[pos + 9])
            pos += 10
            guard pos + rdlen <= b.count else { break }
            let rdata = Array(b[pos..<pos + rdlen])
            if type == 1, rdlen == 4 {
                v4.append(ipString(rdata, family: AF_INET))
            } else if type == 28, rdlen == 16 {
                let s = ipString(rdata, family: AF_INET6)
                if !s.isEmpty { v6.append(s) }
            }
            pos += rdlen
        }
        return (v4, v6)
    }

    // MARK: - System resolvers

    static func systemResolvers() -> [String] {
        guard let state = __res_9_state() else { return [] }
        guard res_9_ninit(state) == 0 else { return [] }
        defer { res_9_ndestroy(state) }
        var servers = [res_9_sockaddr_union](repeating: res_9_sockaddr_union(), count: 8)
        let n = Int(res_9_getservers(state, &servers, Int32(servers.count)))
        var out: [String] = []
        for i in 0..<max(0, min(n, servers.count)) {
            var s = servers[i]
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if Int32(s.sin.sin_family) == AF_INET {
                var a = s.sin.sin_addr
                if inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count)) != nil { out.append(String(cString: buf)) }
            } else if Int32(s.sin6.sin6_family) == AF_INET6 {
                var a = s.sin6.sin6_addr
                if inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count)) != nil { out.append(String(cString: buf)) }
            }
        }
        return out.filter { $0 != dnsServerIP && !$0.hasPrefix("fe80") }
    }
}
