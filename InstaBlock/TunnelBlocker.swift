//
//  TunnelBlocker.swift
//  InstaBlock
//
//  Manages the packet-tunnel VPN configuration that throttles Instagram's
//  media CDNs (see InstaBlockTunnel/PacketTunnelProvider.swift). The tunnel
//  stays connected permanently (on-demand rules); breaks are messages to the
//  running extension, which withdraws its routes and restores them on its own
//  timer — so re-blocking never depends on this app running.
//

import Foundation
import NetworkExtension

enum TunnelBlocker {
    /// Authoritative copy lives in the tunnel provider.
    static let blockedDomains = [
        // Instagram (Meta media CDNs, incl. ISP-hosted *.fna.fbcdn.net caches)
        "fbcdn.net",
        "cdninstagram.com",
        // TikTok (ByteDance video CDNs — dropped outright, not throttled)
        "tiktokcdn.com",
        "tiktokcdn-us.com",
        "tiktokcdn-eu.com",
        "ibytedtos.com",
        "bytefcdn-oversea.com",
        "byteicdn.com",
        "bytedance.map.fastly.net",   // TikTok resolves this CNAME target directly
    ]

    static let providerBundleID = "com.helpon.InstaBlock.tunnel"

    #if targetEnvironment(simulator)
    // NetworkExtension configurations can't run in the simulator;
    // stub the tunnel layer so the UI flow is testable there.
    static func activate(rateKbps: Int, start: Bool = true) async throws {}
    static func isConnected() async -> Bool { true }
    static func isInstalled() async -> Bool { false }   // lets the first-run explainer show in the simulator
    static func startBreak(until end: Date) async throws {}
    static func endBreak() async throws {}
    static func remove() async throws {}
    #else

    private static func loadManager() async throws -> NETunnelProviderManager? {
        try await NETunnelProviderManager.loadAllFromPreferences().first
    }

    /// Whether our VPN configuration exists yet (i.e. the user has already been
    /// through the system's "Add VPN Configurations" prompt).
    static func isInstalled() async -> Bool {
        (try? await loadManager()) != nil
    }

    /// Whether our tunnel is currently connected (or coming up).
    static func isConnected() async -> Bool {
        guard let manager = try? await loadManager() else { return false }
        switch manager.connection.status {
        case .connected, .connecting, .reasserting: return true
        default: return false
        }
    }

    /// Install/refresh the VPN configuration and, when `start` is true, bring
    /// the tunnel up. `rateKbps` is the downstream cap for CDN traffic.
    @discardableResult
    static func activate(rateKbps: Int, start: Bool = true) async throws -> NETunnelProviderManager {
        let manager = try await loadManager() ?? NETunnelProviderManager()

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleID
        proto.serverAddress = "InstaBlock DNS filter"
        proto.providerConfiguration = ["rateKbps": rateKbps]

        manager.protocolConfiguration = proto
        manager.localizedDescription = "InstaBlock"
        manager.isEnabled = true
        let connectRule = NEOnDemandRuleConnect()
        connectRule.interfaceTypeMatch = .any
        manager.onDemandRules = [connectRule]
        manager.isOnDemandEnabled = true

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()

        guard start else { return manager }
        switch manager.connection.status {
        case .connected, .connecting, .reasserting:
            break
        default:
            try manager.connection.startVPNTunnel()
        }
        return manager
    }

    /// Tell the running tunnel to lift the block until `end`. The extension
    /// re-blocks by itself when the time comes.
    static func startBreak(until end: Date) async throws {
        try await send("break:\(Int(end.timeIntervalSince1970))")
    }

    /// Tell the running tunnel to re-block now.
    static func endBreak() async throws {
        try await send("resume")
    }

    /// Remove the VPN configuration entirely.
    static func remove() async throws {
        guard let manager = try await loadManager() else { return }
        try await manager.removeFromPreferences()
    }

    private static func send(_ message: String) async throws {
        guard let manager = try await loadManager(),
              let session = manager.connection as? NETunnelProviderSession else { return }
        // The tunnel may still be coming up (on-demand reconnect); give it a moment.
        for _ in 0..<20 where session.status != .connected {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard session.status == .connected else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try session.sendProviderMessage(Data(message.utf8)) { _ in continuation.resume() }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    #endif
}
