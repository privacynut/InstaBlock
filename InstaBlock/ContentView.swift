//
//  ContentView.swift
//  InstaBlock
//

import SwiftUI
import Combine

struct ContentView: View {
    @State private var controller = BlockController.shared
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
            } else {
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
        controller.isBreakActive ? "play.rectangle.fill" : "video.slash.fill"
    }

    private var statusText: some View {
        Group {
            if controller.isBreakActive {
                Text("Videos allowed — enjoy your break")
            } else {
                Text("Instagram and TikTok videos are blocked")
            }
        }
        .font(.headline)
        .foregroundStyle(.secondary)
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
                VStack(spacing: 6) {
                    Text("ALLOW VIDEOS FOR")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 4)

                    let durations = BlockController.BreakDuration.allCases
                    Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                        ForEach(0..<2, id: \.self) { row in
                            GridRow {
                                ForEach(durations[row * 2 ..< min(row * 2 + 2, durations.count)]) { duration in
                                    Button {
                                        Task { await controller.startBreak(duration) }
                                    } label: {
                                        storyCard(minutes: duration.rawValue)
                                    }
                                    .buttonStyle(StoryTapStyle())
                                }
                            }
                        }
                    }
                }
            }
        }
        .animation(.default, value: controller.isBreakActive)
    }

    /// A big tappable card with an Instagram story ring and the minutes inside.
    private func storyCard(minutes: Int) -> some View {
        GeometryReader { geo in
            let diameter = min(geo.size.width, geo.size.height) * 0.66
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(IGTheme.ring, style: StrokeStyle(lineWidth: diameter * 0.055, lineCap: .round))
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
