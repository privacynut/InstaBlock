//
//  RelayBlocker.swift
//  InstaBlock
//
//  Blocks Instagram video traffic by installing an NERelay configuration
//  that routes *.fbcdn.net through an unreachable relay server. Relay
//  traffic fails closed (no direct fallback), so matched domains are
//  effectively blocked while all other traffic is untouched.
//

import Foundation
import NetworkExtension

enum RelayBlocker {
    /// Instagram serves video (and other media) from these CDN hosts.
    /// matchDomains entries cover the domain and all of its subdomains.
    static let blockedDomains = [
        "fbcdn.net",
        "cdninstagram.com",
        "c10r.facebook.com",
        "c10r.instagram.com"
    ]

    /// A relay server that can never be reached — .invalid never resolves.
    private static let blackholeURL = URL(string: "https://instablock-blackhole.invalid.com:4433/relay")!

    #if targetEnvironment(simulator)
    // NetworkExtension configurations can't be saved in the simulator;
    // stub the relay layer so the UI flow is testable there.
    static func activate() async throws {}
    static func deactivate() async throws {}
    static func remove() async throws {}
    static func currentStatus() async -> String { "Simulator — relay blocking unavailable" }
    #else

    /// Install (or re-enable) the blocking relay configuration.
    static func activate() async throws {
        let manager = NERelayManager.shared()
        try? await manager.loadFromPreferences()

        // Skip the save when the installed config already matches — saving
        // identical config on every foreground pass invites spurious
        // permission/stale errors from the configuration daemon.
        if manager.isEnabled,
           manager.matchDomains == blockedDomains,
           let existing = manager.relays, existing.count == 1,
           existing[0].http3RelayURL == blackholeURL,
           existing[0].http2RelayURL == blackholeURL {
            return
        }

        let relay = NERelay()
        relay.http3RelayURL = blackholeURL
        relay.http2RelayURL = blackholeURL

        manager.relays = [relay]
        manager.matchDomains = blockedDomains
        manager.excludedDomains = []
        manager.localizedDescription = "InstaBlock"
        manager.isEnabled = true
        if #available(iOS 26.0, *) {
            manager.isDNSFailoverAllowed = false
        }
        try await manager.saveToPreferences()
    }

    /// Disable the relay (used during a timed break — videos flow again).
    static func deactivate() async throws {
        let manager = NERelayManager.shared()
        try await manager.loadFromPreferences()
        guard manager.isEnabled else { return }
        manager.isEnabled = false
        try await manager.saveToPreferences()
    }

    /// Remove the configuration entirely (master switch off).
    static func remove() async throws {
        let manager = NERelayManager.shared()
        try await manager.loadFromPreferences()
        try await manager.removeFromPreferences()
    }

    /// Ground truth about what's actually installed on the device,
    /// read back from the system's saved configuration.
    static func currentStatus() async -> String {
        let manager = NERelayManager.shared()
        do {
            try await manager.loadFromPreferences()
        } catch {
            return "Relay config couldn't be read: \(error.localizedDescription)"
        }
        guard let relays = manager.relays, !relays.isEmpty else {
            return "Relay config NOT installed"
        }
        let domains = (manager.matchDomains ?? []).joined(separator: ", ")
        var status = manager.isEnabled
            ? "Relay active — matching: \(domains)"
            : "Relay installed but disabled (break) — matching: \(domains)"

        // Recent connection attempts through the relay (last hour): proof of
        // whether the system is actually diverting matched traffic into it.
        if #available(iOS 18.0, *) {
            let clientErrors = await withCheckedContinuation { continuation in
                manager.getLastClientErrors(3600) { errors in
                    continuation.resume(returning: errors ?? [])
                }
            }
            if !clientErrors.isEmpty {
                let codes = clientErrors.prefix(5).map { "\(($0 as NSError).code)" }.joined(separator: ",")
                status += "\nRelay attempts last hour (codes): \(codes)"
            } else {
                status += "\nNo relay connection attempts in the last hour"
            }
        }
        return status
    }
    #endif
}
