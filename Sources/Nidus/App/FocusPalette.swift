//
//  FocusPalette.swift
//  Nidus
//
//  A thin façade over Solanum's one palette: clay is `Solanum.focus`, and
//  the stats graph's shades are focus at rising strength on the empty track.
//

import SwiftUI

enum FocusPalette {
    /// Clay, Solanum's focus colour.
    static let clay = Solanum.focus

    /// How strong clay is at a graph level (1 through 4); the top level is
    /// full under Increased Contrast, and the lower ones are raised.
    static func graphOpacity(level: Int, contrast: ColorSchemeContrast = .standard) -> Double {
        let normal = [0.3, 0.5, 0.75, 1.0]
        let increased = [0.55, 0.7, 0.85, 1.0]
        let steps = contrast == .increased ? increased : normal
        return steps[min(max(level, 1), 4) - 1]
    }

    /// The stats graph's five shades: the empty track, then focus at rising strength.
    static func graphShade(level: Int, contrast: ColorSchemeContrast = .standard) -> Color {
        level <= 0 ? Solanum.track(contrast) : Solanum.focus.opacity(graphOpacity(level: level, contrast: contrast))
    }
}
