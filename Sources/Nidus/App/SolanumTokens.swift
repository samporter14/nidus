// SolanumTokens.swift — Solanum's colours in both themes, the chart palette
// and the type scale. The widget extension compiles this file too
// (Scripts/build-app.sh), so it holds values only: no views, nothing from the
// app target.
//
// One meaning per colour:
//  - clay is focus and the accent, nothing else (a fill; words use clayText);
//  - `work` is time that counts as work, `distracting` is drift, `other` is
//    everything that is neither;
//  - categories and apps take one of eight `series` hues, chosen to read on
//    both grounds (3.7:1 or more on ivory and on slate) and to stay clear of
//    clay, work and distracting.
import AppKit
import SwiftUI

enum Solanum {
    /// Ivory in light, slate in dark: the ground of every tab.
    static let page = adaptive(light: 0xFAF9F5, dark: 0x141413)
    /// Cards on the page.
    static let raised = adaptive(light: 0xFFFFFF, dark: 0x262625)
    static let ink = adaptive(light: 0x141413, dark: 0xFAF9F5)
    /// Hints, secondary words and numbers people read. 6.3:1 light, 8.4:1 dark.
    static let inkMuted = adaptive(light: 0x5E5D59, dark: 0xB0AEA5)
    /// Mono overlines and other faint words, 11 pt and up, on the page.
    static let inkFaint = adaptive(light: 0x73726C, dark: 0x91918D)
    static let hairline = adaptive(light: (31, 30, 29, 0.15), dark: (250, 249, 245, 0.18))
    /// Control borders and focus rings; card edges under Increased Contrast.
    static let strong = adaptive(light: (31, 30, 29, 0.3), dark: (250, 249, 245, 0.32))
    /// The accent, as a fill only: 2.96:1 on the page, so never text.
    static let clay = Color(nsColor: NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1))
    /// Words and symbols on a clay fill: ink, in both themes (6:1).
    static let onClay = Color(nsColor: NSColor(srgbRed: 0x14 / 255, green: 0x14 / 255, blue: 0x13 / 255, alpha: 1))
    /// Clay read as words: clay itself is too faint for text.
    static let clayText = adaptive(light: 0x9C4221, dark: 0xE4927A)
    /// The raised segment of a segmented control, and its well.
    static let segmentOn = adaptive(light: 0xFFFFFF, dark: 0x3A3935)
    static let segmentWell = adaptive(light: (31, 30, 29, 0.06), dark: (250, 249, 245, 0.08))

    // MARK: Chart palette

    /// Time in focus. The same clay as the accent: focus is what Nidus is for.
    static let focus = clay
    /// Time that counts as work (the Work group, categories set to work).
    static let work = adaptive(light: 0x5E8A6C, dark: 0x8DBB98)
    /// Time that counts as drift. Plum: never clay, 5.2:1 ivory, 7.4:1 slate.
    static let distracting = adaptive(light: 0x9A4F8A, dark: 0xD08FC2)
    /// Time that belongs to no one thing ("Other", Uncategorized).
    static let other = adaptive(light: 0x8A8880, dark: 0x77766F)
    /// The empty part of every bar, track and grid cell.
    static let track = adaptive(light: (31, 30, 29, 0.07), dark: (250, 249, 245, 0.08))
    /// The same under Increased Contrast.
    static let trackStrong = adaptive(light: (31, 30, 29, 0.16), dark: (250, 249, 245, 0.18))

    /// How many category and app hues there are.
    static let seriesCount = 8

    /// One of the eight category and app hues; any integer is folded in.
    static func series(_ slot: Int) -> Color {
        let all = seriesColors
        return all[((slot % all.count) + all.count) % all.count]
    }

    /// Their names, for the colour picker and VoiceOver, in slot order.
    static let seriesNames = ["Blue", "Teal", "Gold", "Violet", "Olive", "Rose", "Steel", "Umber"]

    private static let seriesColors: [Color] = [
        adaptive(light: 0x4F7FA8, dark: 0x86AECE), // blue
        adaptive(light: 0x3F8C86, dark: 0x6FBDB5), // teal
        adaptive(light: 0x9A7A2E, dark: 0xD4AE5E), // gold
        adaptive(light: 0x7B6FAE, dark: 0xADA3D9), // violet
        adaptive(light: 0x6F8040, dark: 0xA9BA72), // olive
        adaptive(light: 0xB05C6E, dark: 0xE08E9F), // rose
        adaptive(light: 0x5F7287, dark: 0x9DAEC2), // steel
        adaptive(light: 0x8C6A4E, dark: 0xC6A283), // umber
    ]

    // MARK: Increased Contrast

    /// A card's or a chart's edge: hairline, or `strong` when the user asked
    /// for more contrast.
    static func edge(_ contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? strong : hairline
    }

    /// An empty track or cell, firmer when the user asked for more contrast.
    static func track(_ contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? trackStrong : track
    }

    /// A series fill's opacity: full under Increased Contrast.
    static func fillOpacity(_ base: Double, _ contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? 1 : base
    }

    // MARK: Radii

    /// Bars, cells and small marks in charts.
    static let markRadius: CGFloat = 2
    /// Tracks, wells and chart frames.
    static let frameRadius: CGFloat = 6

    // MARK: Type

    /// Serif for display (the system's New York), sans for reading.
    static func serif(_ size: CGFloat) -> Font { .system(size: size, design: .serif) }

    // MARK: Colour plumbing

    private static func adaptive(light: Int, dark: Int) -> Color {
        adaptive(light: rgb(light), dark: rgb(dark))
    }

    private static func adaptive(light: (Int, Int, Int, Double), dark: (Int, Int, Int, Double)) -> Color {
        adaptive(light: rgba(light), dark: rgba(dark))
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func rgba(_ c: (Int, Int, Int, Double)) -> NSColor {
        NSColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: c.3)
    }
}

/// Solanum's type scale: six steps. Nothing is set below 10 pt, and faint
/// ink (`inkFaint`) never below 11 pt.
///
///  - display: serif 28, the big figures and the clock;
///  - title: 14 semibold, a card's or a row's name;
///  - body: 13, reading text;
///  - label: 12 medium, list rows, buttons, legends;
///  - caption: 11, hints, axis labels, small figures;
///  - overline: mono 11, a section's label (uppercase, tracked).
enum SolanumType: CaseIterable {
    case display, title, body, label, caption, overline

    var size: CGFloat {
        switch self {
        case .display: return 28
        case .title: return 14
        case .body: return 13
        case .label: return 12
        case .caption, .overline: return 11
        }
    }

    var defaultWeight: Font.Weight {
        switch self {
        case .title: return .semibold
        case .label: return .medium
        default: return .regular
        }
    }

    var design: Font.Design {
        switch self {
        case .display: return .serif
        case .overline: return .monospaced
        default: return .default
        }
    }
}

extension Font {
    /// A step of Solanum's type scale, optionally in another weight or
    /// design (rounded figures in a chart, say).
    static func solanum(_ step: SolanumType, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        .system(size: step.size, weight: weight ?? step.defaultWeight, design: design ?? step.design)
    }

    /// The one big-number style, for Activity's and Stats' figures: serif
    /// display with figures that line up.
    static let solanumFigure = Font.system(size: SolanumType.display.size, weight: .regular, design: .serif).monospacedDigit()

    /// A smaller figure, for a card with several (a session's detail).
    static let solanumFigureSmall = Font.system(size: 20, weight: .regular, design: .serif).monospacedDigit()
}
