//
//  InstaBlockApp.swift
//  InstaBlock
//

import SwiftUI
import BackgroundTasks

@main
struct InstaBlockApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Must be registered before the app finishes launching.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BlockController.backgroundTaskID,
            using: .main
        ) { task in
            Task { @MainActor in
                await BlockController.shared.reconcile()
                task.setTaskCompleted(success: true)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task { await BlockController.shared.reconcile() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await BlockController.shared.reconcile() }
            case .background:
                BlockController.shared.scheduleBackgroundRefreshIfNeeded()
            default:
                break
            }
        }
    }
}
