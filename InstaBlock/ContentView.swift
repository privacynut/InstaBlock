//
//  ContentView.swift
//  InstaBlock
//

import SwiftUI
import Combine

struct ContentView: View {
    @State private var controller = BlockController.shared
    @State private var holding: BlockController.BreakDuration?
    @State private var holdProgress: Double = 0
    @State private var holdStart: Date?
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 20) {
                wordmark
                statusRing
                statusText
                breakControls
                    .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .onReceive(ticker) { _ in controller.tick() }
        .sheet(isPresented: Binding(get: { controller.needsVPNIntro }, set: { _ in })) {
            VPNIntroView { Task { await controller.acknowledgeVPNIntro() } }
                .interactiveDismissDisabled()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { controller.lastError != nil },
                set: { if !$0 { controller.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.lastError ?? "")
        }
    }

    // MARK: - Header

    private var wordmark: some View {
        Text("InstaBlock")
            .font(.custom("SnellRoundhand-Bold", size: 40))
            .foregroundStyle(IGTheme.gradient)
            .padding(.top, 8)
    }

    // MARK: - Status ring

    private var statusRing: some View {
        ZStack {
            // Track
            Circle()
                .stroke(Color(.systemGray5), lineWidth: 10)

            if controller.isBreakActive {
                // Countdown ring drains as the break runs out
                Circle()
                    .trim(from: 0, to: controller.breakProgress)
                    .stroke(IGTheme.ring, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: controller.breakProgress)
            } else if controller.tunnelUp {
                Circle()
                    .stroke(IGTheme.ring, style: StrokeStyle(lineWidth: 10, lineCap: .round))
            }

            VStack(spacing: 10) {
                Image(systemName: ringIcon)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(IGTheme.gradient)

                if controller.isBreakActive {
                    Text(controller.remainingLabel)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.default, value: controller.remainingLabel)
                }
            }
        }
        .frame(width: 200, height: 200)
        .padding(.vertical, 4)
    }

    private var ringIcon: String {
        if controller.isBreakActive { return "play.rectangle.fill" }
        return controller.tunnelUp ? "video.slash.fill" : "pause.circle.fill"
    }

    private var needsTurnOn: Bool { !controller.isBreakActive && !controller.tunnelUp }

    private var statusText: some View {
        VStack(spacing: 10) {
            Group {
                if controller.isBreakActive {
                    Text("Videos allowed — enjoy your break")
                } else if controller.pausedByOtherVPN {
                    Text("Paused — another VPN is active")
                } else if !controller.tunnelUp {
                    Text("Not blocking — InstaBlock is off")
                } else {
                    Text("Instagram and TikTok videos are blocked")
                }
            }
            .font(.headline)
            .foregroundStyle(.secondary)

            if needsTurnOn {
                Button {
                    Task { await controller.reenable() }
                } label: {
                    Text("Turn InstaBlock back on")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Capsule().fill(IGTheme.gradient))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Break controls (one tap, fills the rest of the screen)

    private var breakControls: some View {
        Group {
            if controller.isBreakActive {
                Button {
                    Task { await controller.endBreak() }
                } label: {
                    VStack(spacing: 14) {
                        Image(systemName: "video.slash.fill")
                            .font(.system(size: 44, weight: .semibold))
                        Text("Block videos now")
                            .font(.title2.weight(.bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(IGTheme.gradient))
                }
                .buttonStyle(StoryTapStyle())
            } else {
                VStack(spacing: 10) {
                    Text(controller.isCoolingDown ? "NEXT BREAK IN \(controller.cooldownLabel)" : "ALLOW VIDEOS FOR")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)

                    if !controller.isCoolingDown { holdHint }

                    let durations = BlockController.BreakDuration.allCases
                    Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                        ForEach(0..<2, id: \.self) { row in
                            GridRow {
                                ForEach(durations[row * 2 ..< min(row * 2 + 2, durations.count)]) { duration in
                                    storyCard(minutes: duration.rawValue,
                                              progress: holding == duration ? holdProgress : 0)
                                        .scaleEffect(holding == duration ? 0.96 : 1)
                                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: holding)
                                        .onLongPressGesture(
                                            minimumDuration: BlockController.holdToStartSeconds,
                                            maximumDistance: 40
                                        ) {
                                            holding = nil
                                            holdStart = nil
                                            holdProgress = 0
                                            Task { await controller.startBreak(duration) }
                                        } onPressingChanged: { pressing in
                                            if pressing {
                                                holding = duration
                                                holdStart = Date()
                                                holdProgress = 0
                                                withAnimation(.linear(duration: BlockController.holdToStartSeconds)) {
                                                    holdProgress = 1
                                                }
                                            } else {
                                                holding = nil
                                                holdStart = nil
                                                withAnimation(.easeOut(duration: 0.25)) { holdProgress = 0 }
                                            }
                                        }
                                }
                            }
                        }
                    }
                    .disabled(controller.isCoolingDown)
                    .opacity(controller.isCoolingDown ? 0.45 : 1)
                }
            }
        }
        .animation(.default, value: controller.isBreakActive)
    }

    /// Full-width instruction pill. Idle: "hold a card". While a card is held it
    /// fills with the gradient and counts the remaining seconds down.
    private var holdHint: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            let remaining = max(0, BlockController.holdToStartSeconds - ctx.date.timeIntervalSince(holdStart ?? ctx.date))
            let active = holding != nil
            HStack(spacing: 10) {
                Image(systemName: active ? "hand.tap.fill" : "hand.tap")
                    .font(.title3.weight(.semibold))
                if active {
                    Text("Keep holding…  \(Int(remaining.rounded(.up)))")
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                } else {
                    Text("Hold a card for \(Int(BlockController.holdToStartSeconds)) seconds to allow videos")
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(active ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                Capsule().fill(active ? AnyShapeStyle(IGTheme.gradient) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)))
            )
            .overlay(Capsule().stroke(Color.primary.opacity(active ? 0 : 0.12), lineWidth: 1))
            .animation(.easeInOut(duration: 0.2), value: active)
        }
    }

    /// A big card with an Instagram story ring and the minutes inside. While the
    /// user holds it, a dark arc sweeps around the ring to show hold progress.
    private func storyCard(minutes: Int, progress: Double) -> some View {
        GeometryReader { geo in
            let diameter = min(geo.size.width, geo.size.height) * 0.66
            let stroke = diameter * 0.055
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(IGTheme.ring, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                        .frame(width: diameter, height: diameter)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.primary.opacity(0.85), style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: diameter, height: diameter)
                    Circle()
                        .fill(Color(.systemBackground))
                        .frame(width: diameter * 0.84, height: diameter * 0.84)
                    Text("\(minutes)")
                        .font(.system(size: diameter * 0.40, weight: .bold, design: .rounded))
                        .foregroundStyle(IGTheme.gradient)
                }
                Text(minutes == 1 ? "minute" : "minutes")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

/// Shown once, before iOS asks to add the VPN configuration, so the system
/// prompt isn't the first thing a new user sees.
struct VPNIntroView: View {
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(IGTheme.gradient)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 28)

                    Text("One quick permission")
                        .font(.title.weight(.bold))
                        .frame(maxWidth: .infinity, alignment: .center)

                    Text("Next, iPhone will ask to add a VPN configuration. That sounds bigger than it is:")
                        .font(.body)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 16) {
                        introRow("slash.circle.fill", "It's how iOS lets an app filter traffic — InstaBlock uses it to slow Instagram and TikTok video to a stall.")
                        introRow("iphone", "It runs only on your phone. There's no server, no account, and nothing leaves your device.")
                        introRow("message.fill", "Messages, photos, stories and every other app are untouched.")
                        introRow("antenna.radiowaves.left.and.right", "A VPN badge shows in the status bar while blocking is on. That's the filter running.")
                    }

                    Text("Tap Allow on the next screens — the VPN one, and one for notifications so InstaBlock can tell you when a break ends or blocking is off. If you tap Don't Allow on the VPN prompt, iOS won't ask again until the app is reinstalled.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }

            Button(action: onContinue) {
                Text("Continue")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IGTheme.gradient))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: 520)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func introRow(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(IGTheme.gradient)
                .frame(width: 30)
            Text(text).font(.body)
        }
    }
}

/// Story-bubble press feedback: a quick shrink, like tapping a story.
private struct StoryTapStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

#Preview {
    ContentView()
}
