//
//  BlockController.swift
//  InstaBlock
//
//  State machine for the block / timed-break lifecycle. The tunnel extension
//  owns the break timer and re-blocks by itself when it expires (the app is
//  usually not running then); this side keeps the countdown UI, persists the
//  end date, schedules the notification, and re-syncs on every activation.
//

import Foundation
import BackgroundTasks
import Observation
import UserNotifications

@MainActor
@Observable
final class BlockController {
    static let shared = BlockController()

    static let backgroundTaskID = "com.helpon.InstaBlock.reblock"
    private static let notificationID = "com.helpon.InstaBlock.break-ended"

    enum BreakDuration: Int, CaseIterable, Identifiable {
        case oneMinute = 1
        case fiveMinutes = 5
        case fifteenMinutes = 15
        case thirtyMinutes = 30

        var id: Int { rawValue }
        var seconds: TimeInterval { TimeInterval(rawValue * 60) }
        var label: String { "\(rawValue) min" }
    }

    private(set) var breakEndDate: Date?
    var selectedDuration: BreakDuration {
        didSet { defaults.set(selectedDuration.rawValue, forKey: Keys.duration) }
    }
    private(set) var now = Date()
    var lastError: String?

    /// Downstream cap for Instagram CDN traffic. Photos and videos share the
    /// same hosts, so bandwidth is the lever: 150 kbps lets photos load while
    /// video stalls (tuned on-device).
    static let throttleKbps = 150

    private var isEndingBreak = false
    private var isReconciling = false
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let breakEnd = "breakEndDate"
        static let duration = "breakDurationMinutes"
        static let relayRemoved = "relayConfigRemoved"
    }

    private init() {
        breakEndDate = defaults.object(forKey: Keys.breakEnd) as? Date
        selectedDuration = BreakDuration(rawValue: defaults.integer(forKey: Keys.duration)) ?? .fiveMinutes
    }

    var isBreakActive: Bool { breakEndDate != nil }

    var remainingSeconds: TimeInterval {
        guard let end = breakEndDate else { return 0 }
        return max(0, end.timeIntervalSince(now))
    }

    var breakProgress: Double {
        guard isBreakActive, selectedDuration.seconds > 0 else { return 0 }
        return min(1, remainingSeconds / selectedDuration.seconds)
    }

    var remainingLabel: String {
        let total = Int(remainingSeconds.rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Called every second while the UI is visible.
    func tick() {
        now = Date()
        if let end = breakEndDate, end <= now, !isEndingBreak {
            Task { await endBreak() }
        }
    }

    // MARK: - Timed break (videos allowed)

    /// One tap: allow videos for `duration`, then re-block automatically.
    func startBreak(_ duration: BreakDuration) async {
        guard !isBreakActive else { return }
        selectedDuration = duration
        do {
            await requestNotificationPermission()
            let end = Date().addingTimeInterval(duration.seconds)
            try await TunnelBlocker.activate(rateKbps: Self.throttleKbps)
            try await TunnelBlocker.startBreak(until: end)
            breakEndDate = end
            defaults.set(end, forKey: Keys.breakEnd)
            scheduleEndNotification(at: end)
            scheduleBackgroundRefreshIfNeeded()
            lastError = nil
        } catch {
            lastError = "Couldn't pause the block: \(error.localizedDescription)"
        }
    }

    func endBreak() async {
        guard isBreakActive, !isEndingBreak else { return }
        isEndingBreak = true
        defer { isEndingBreak = false }
        do {
            try await TunnelBlocker.activate(rateKbps: Self.throttleKbps)
            try await TunnelBlocker.endBreak()
            clearBreakState()
            lastError = nil
        } catch {
            lastError = "Couldn't resume the block: \(error.localizedDescription)"
        }
    }

    /// Bring reality in line with stored state. Called on launch, on
    /// foreground activation, and from the background refresh task.
    /// Blocking is always on while the app is installed, except during
    /// an active break.
    func reconcile() async {
        // The window's .task and the scenePhase handler both fire at launch;
        // two concurrent load/save sequences race the config daemon (and the
        // first-run consent flow) and fail with permission/stale errors.
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }

        // One-time migration: retire the old NERelay-based block, which
        // Instagram's own networking stack bypassed.
        if !defaults.bool(forKey: Keys.relayRemoved) {
            try? await RelayBlocker.remove()
            defaults.set(true, forKey: Keys.relayRemoved)
        }

        now = Date()
        if let end = breakEndDate, end <= now {
            await endBreak()
        } else {
            // Re-assert the config (and the tunnel) in case it was tampered
            // with, then re-sync the break state with the extension.
            do {
                try await TunnelBlocker.activate(rateKbps: Self.throttleKbps)
                if let end = breakEndDate {
                    try await TunnelBlocker.startBreak(until: end)
                } else {
                    try await TunnelBlocker.endBreak()
                }
            } catch {
                let ns = error as NSError
                if ns.domain == "NEConfigurationErrorDomain", ns.code == 10 {
                    // First save shows the system's "Would Like to Add VPN
                    // Configurations" consent alert; a recorded "Don't Allow"
                    // makes every later save fail until the app is reinstalled.
                    lastError = """
                    iOS refused the VPN configuration (permission denied). \
                    This usually means "Don't Allow" was tapped on the system's \
                    "Add VPN Configurations" prompt. Delete InstaBlock, \
                    reinstall it, and tap Allow when the prompt appears.
                    """
                } else {
                    lastError = "Couldn't install the block: \(ns.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Background & notifications

    func scheduleBackgroundRefreshIfNeeded() {
        guard let end = breakEndDate else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskID)
        request.earliestBeginDate = end
        try? BGTaskScheduler.shared.submit(request)
    }

    private func clearBreakState() {
        breakEndDate = nil
        defaults.removeObject(forKey: Keys.breakEnd)
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }

    private func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    private func scheduleEndNotification(at date: Date) {
        let content = UNMutableNotificationContent()
        content.title = "Time's up"
        content.body = "Break over — Instagram and TikTok videos are blocked again."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, date.timeIntervalSinceNow),
            repeats: false
        )
        let request = UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
}
