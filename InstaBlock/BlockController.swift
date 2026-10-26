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
    static let processingTaskID = "com.helpon.InstaBlock.reblock.processing"
    private static let notificationID = "com.helpon.InstaBlock.break-ended"

    enum BreakDuration: Int, CaseIterable, Identifiable {
        case oneMinute = 1
        case fiveMinutes = 5
        case fifteenMinutes = 15
        case thirtyMinutes = 30

        var id: Int { rawValue }
        var seconds: TimeInterval { TimeInterval(rawValue * 60) }
        var label: String { "\(rawValue) min" }
        /// Cooldown after this break: same number, in seconds, at least 5.
        var cooldownSeconds: TimeInterval { max(5, TimeInterval(rawValue)) }
    }

    private(set) var breakEndDate: Date?
    /// After a break ends, the duration cards are locked until this date:
    /// a short rhythm-breaker (break minutes → seconds, min 5 s) so a break
    /// can't be chained into a session with one tap.
    private(set) var cooldownEnd: Date?
    /// The first-run explainer is showing; the VPN config is not installed until
    /// the user continues from it (which is what triggers the system prompt).
    private(set) var needsVPNIntro = false
    /// Starting a break requires holding a card this long — friction at the
    /// decision point, which is where the evidence says it works best.
    static let holdToStartSeconds: TimeInterval = 5
    var selectedDuration: BreakDuration {
        didSet { defaults.set(selectedDuration.rawValue, forKey: Keys.duration) }
    }
    private(set) var now = Date()
    var lastError: String?

    /// True while another VPN holds the device's VPN slot and our tunnel is down.
    private(set) var pausedByOtherVPN = false
    /// Whether our tunnel is actually connected (or coming up). The UI must
    /// never claim "blocked" when this is false.
    private(set) var tunnelUp = false

    /// Downstream cap for Instagram CDN traffic. Photos and videos share the
    /// same hosts, so bandwidth is the lever: 150 kbps lets photos load while
    /// video stalls (tuned on-device).
    static let throttleKbps = 150

    private var isEndingBreak = false
    private var isReconciling = false
    /// When our tunnel was last seen going down in this process. Another VPN
    /// starting tears ours down *before* its own interface appears, so an
    /// immediate restart would evict it. Hold off for a grace period first.
    private var tunnelDroppedAt: Date?
    private var retryTask: Task<Void, Never>?
    private static let restartGrace: TimeInterval = 20
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let breakEnd = "breakEndDate"
        static let duration = "breakDurationMinutes"
        static let relayRemoved = "relayConfigRemoved"
        static let cooldownEnd = "cooldownEndDate"
        static let vpnIntroDone = "vpnIntroDone"
    }

    private init() {
        breakEndDate = defaults.object(forKey: Keys.breakEnd) as? Date
        selectedDuration = BreakDuration(rawValue: defaults.integer(forKey: Keys.duration)) ?? .fiveMinutes
        cooldownEnd = defaults.object(forKey: Keys.cooldownEnd) as? Date
    }

    var isBreakActive: Bool { breakEndDate != nil }
    var isCoolingDown: Bool { cooldownEnd.map { $0 > now } ?? false }
    var cooldownRemaining: TimeInterval { max(0, cooldownEnd?.timeIntervalSince(now) ?? 0) }
    var cooldownLabel: String {
        let total = Int(cooldownRemaining.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

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
        if let cd = cooldownEnd, cd <= now {
            cooldownEnd = nil
            defaults.removeObject(forKey: Keys.cooldownEnd)
        }
    }

    /// Lock the duration cards for the cooldown that follows a break. The
    /// cooldown is anchored to when the break actually ended, so a break that
    /// expired while the app was closed doesn't restart the clock on launch.
    private func startCooldown(from breakEnd: Date) {
        let end = breakEnd.addingTimeInterval(selectedDuration.cooldownSeconds)
        guard end > Date() else { return }
        cooldownEnd = end
        defaults.set(end, forKey: Keys.cooldownEnd)
    }

    // MARK: - Timed break (videos allowed)

    /// One tap: allow videos for `duration`, then re-block automatically.
    /// The user read the explainer: install the configuration now, which is the
    /// moment iOS shows its own consent prompt.
    func acknowledgeVPNIntro() async {
        defaults.set(true, forKey: Keys.vpnIntroDone)
        needsVPNIntro = false
        await reconcile()
    }

    func startBreak(_ duration: BreakDuration) async {
        guard !isBreakActive, !isCoolingDown, !needsVPNIntro else { return }
        selectedDuration = duration
        do {
            let end = Date().addingTimeInterval(duration.seconds)
            // Only (re)start our tunnel if that won't evict another VPN; while
            // paused, a break is just bookkeeping — videos already flow.
            if await canTakeVPNSlot() {
                try await TunnelBlocker.activate(rateKbps: Self.throttleKbps)
                try await TunnelBlocker.startBreak(until: end)
            }
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
        // Ending early: cooldown runs from now. Expired: from the scheduled end.
        startCooldown(from: min(breakEndDate ?? Date(), Date()))
        do {
            if await canTakeVPNSlot() {
                try await TunnelBlocker.activate(rateKbps: Self.throttleKbps)
                try await TunnelBlocker.endBreak()
                tunnelUp = true
            }
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
        // First run: explain, in our own words, why the "Add VPN Configurations"
        // prompt is about to appear — before iOS shows it (or the notification
        // one). Nothing is installed until the user continues from the explainer.
        if !defaults.bool(forKey: Keys.vpnIntroDone) {
            if await TunnelBlocker.isInstalled() {
                defaults.set(true, forKey: Keys.vpnIntroDone)   // existing install: never show
            } else {
                needsVPNIntro = true
                return
            }
        }
        await requestNotificationPermission()

        now = Date()
        if let end = breakEndDate, end <= now {
            await endBreak()
            return
        }

        // iOS allows one VPN at a time. If another one is up and ours isn't,
        // leave it alone (starting ours would kick it off) and show "paused".
        let ourTunnelUp = await TunnelBlocker.isConnected()
        let otherVPN = ourTunnelUp ? false : await VPNDetector.otherVPNActive()
        pausedByOtherVPN = otherVPN

        if ourTunnelUp {
            tunnelDroppedAt = nil
        } else if tunnelUp {
            tunnelDroppedAt = Date()   // it was up a moment ago: it just dropped
        }
        tunnelUp = ourTunnelUp

        // Just dropped and no other VPN visible yet? Don't race it — check again
        // after the grace period instead of restarting now.
        if !ourTunnelUp, !otherVPN, let dropped = tunnelDroppedAt,
           Date().timeIntervalSince(dropped) < Self.restartGrace {
            scheduleRetry(after: Self.restartGrace - Date().timeIntervalSince(dropped))
            return
        }

        do {
            if !ourTunnelUp {
                // Saving our configuration marks it *enabled*, and iOS allows only
                // one enabled VPN configuration — so a save alone evicts whatever
                // VPN is active. Never touch the config while another VPN holds
                // the slot; re-enable (save) and start only when the slot is free.
                guard !otherVPN else { return }
                try await TunnelBlocker.activate(rateKbps: Self.throttleKbps, start: true)
                tunnelUp = true
            }
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

    /// True when starting/saving our tunnel config won't evict another VPN:
    /// either ours is already up, or no other VPN interface is present.
    private func canTakeVPNSlot() async -> Bool {
        if await TunnelBlocker.isConnected() { return true }
        return !(await VPNDetector.otherVPNActive())
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.5, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.reconcile()
        }
    }

    /// Explicit user request (notification action or in-app button): take the
    /// VPN slot back even if another VPN is currently connected.
    func reenable() async {
        retryTask?.cancel()
        tunnelDroppedAt = nil
        do {
            try await TunnelBlocker.activate(rateKbps: Self.throttleKbps, start: true)
            pausedByOtherVPN = false
            tunnelUp = true
            lastError = nil
        } catch {
            lastError = "Couldn't turn InstaBlock back on: \(error.localizedDescription)"
        }
    }

    /// Network path or VPN status changed while the app is open. A full
    /// reconcile, not just an indicator refresh: another VPN's interface can
    /// linger a few seconds after it disconnects, so the first pass may have
    /// (correctly) declined to start our tunnel — this pass starts it.
    func refreshPausedState() async {
        await reconcile()
    }

    // MARK: - Background & notifications

    /// Best-effort periodic wake-up: iOS runs it when it likes. It re-syncs a
    /// finished break and, if another VPN has since disconnected, brings our
    /// tunnel back without the user opening the app.
    func scheduleBackgroundRefresh() {
        let soon = Date().addingTimeInterval(15 * 60)
        let earliest = breakEndDate.map { min($0, soon) } ?? soon
        let refresh = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskID)
        refresh.earliestBeginDate = earliest
        try? BGTaskScheduler.shared.submit(refresh)
        // A processing task is granted under different conditions (idle, often
        // charging) than app refresh — a second chance to notice the other VPN left.
        let processing = BGProcessingTaskRequest(identifier: Self.processingTaskID)
        processing.earliestBeginDate = earliest
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(processing)
    }

    func scheduleBackgroundRefreshIfNeeded() { scheduleBackgroundRefresh() }

    private func clearBreakState() {
        breakEndDate = nil
        defaults.removeObject(forKey: Keys.breakEnd)
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }

    private func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        // Categories used by the tunnel extension's "InstaBlock is off" alert.
        let reenable = UNNotificationAction(identifier: "REENABLE", title: "Turn InstaBlock back on", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "VPN_PAUSED", actions: [reenable], intentIdentifiers: []),
            UNNotificationCategory(identifier: "VPN_RESUMED", actions: [], intentIdentifiers: []),
        ])
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
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
