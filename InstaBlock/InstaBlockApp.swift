//
//  InstaBlockApp.swift
//  InstaBlock
//

import SwiftUI
import BackgroundTasks
import Network
import NetworkExtension
import UserNotifications

@main
struct InstaBlockApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    /// While the app is open, any network path change (VPN up/down, Wi-Fi <->
    /// cellular) re-evaluates the paused state. Callbacks need a live process,
    /// so this cannot see changes while the app is suspended.
    private let pathMonitor = NWPathMonitor()

    init() {
        // Must be registered before the app finishes launching.
        for id in [BlockController.backgroundTaskID, BlockController.processingTaskID] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { task in
                Task { @MainActor in
                    await BlockController.shared.reconcile()
                    BlockController.shared.scheduleBackgroundRefresh()
                    task.setTaskCompleted(success: true)
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    pathMonitor.pathUpdateHandler = { _ in
                        Task { @MainActor in await BlockController.shared.refreshPausedState() }
                    }
                    pathMonitor.start(queue: .main)
                    await BlockController.shared.reconcile()
                }
                .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
                    Task { await BlockController.shared.refreshPausedState() }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await BlockController.shared.reconcile() }
            case .background:
                BlockController.shared.scheduleBackgroundRefresh()
            default:
                break
            }
        }
    }
}

/// Handles the "Turn InstaBlock back on" notification action, which iOS
/// delivers to the app in the background — no need to open it.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        guard category == "VPN_PAUSED" else { return }
        if action == "REENABLE" {
            await BlockController.shared.reenable()
        } else {
            // Tapping the alert opens the app; reconcile decides whether it's safe to start.
            await BlockController.shared.reconcile()
        }
    }
}
