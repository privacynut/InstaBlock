//
//  Theme.swift
//  InstaBlock
//

import SwiftUI

extension Color {
    init(hex: UInt) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

enum IGTheme {
    static let blue = Color(hex: 0x405DE6)
    static let purple = Color(hex: 0x833AB4)
    static let magenta = Color(hex: 0xC13584)
    static let pink = Color(hex: 0xE1306C)
    static let red = Color(hex: 0xFD1D1D)
    static let orange = Color(hex: 0xF77737)
    static let yellow = Color(hex: 0xFCAF45)

    static let gradientColors: [Color] = [blue, purple, magenta, pink, red, orange, yellow]

    static var gradient: LinearGradient {
        LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // Story-ring style gradient
    static var ring: AngularGradient {
        AngularGradient(
            colors: [yellow, orange, red, pink, magenta, purple, blue, yellow],
            center: .center,
            angle: .degrees(-90)
        )
    }
}
