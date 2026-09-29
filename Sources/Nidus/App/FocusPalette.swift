//
//  FocusPalette.swift
//  Nidus
//
//  Clay, Solanum's one accent, and the stats graph's shades of it. The rest
//  of the palette is the system's own.
//

import SwiftUI

enum FocusPalette {
    /// Clay, #d97757.
    static let clay = Color(.sRGB, red: 217 / 255, green: 119 / 255, blue: 87 / 255, opacity: 1)

    /// The stats graph's five shades: none, then clay at rising strength.
    static func graphShade(level: Int) -> Color {
        switch level {
        case 0: return Color.primary.opacity(0.08)
        case 1: return clay.opacity(0.3)
        case 2: return clay.opacity(0.5)
        case 3: return clay.opacity(0.75)
        default: return clay
        }
    }
}
