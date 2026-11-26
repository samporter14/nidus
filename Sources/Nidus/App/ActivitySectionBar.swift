//
//  ActivitySectionBar.swift
//  Nidus
//
//  A quiet row of plain buttons over the Activity page that scrolls to each
//  section and marks the one in view. Lighter than SolanumSegmented: the
//  section in view gets the raised pill, the rest are just words.
//

import SwiftUI

enum ActivitySection: String, CaseIterable, Identifiable, Hashable {
    case overview, day, bars, week, hours, drift, apps, sessions
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .day: return "Day"
        case .bars: return "Bars"
        case .week: return "Week"
        case .hours: return "Hours"
        case .drift: return "Drift"
        case .apps: return "Apps"
        case .sessions: return "Sessions"
        }
    }

    /// The sections a period shows, top to bottom. A day has its ribbon; a
    /// week or a month has the daily bars instead.
    static func shown(for period: ActivityPeriod) -> [ActivitySection] {
        [.overview, period == .today ? .day : .bars, .week, .hours, .drift, .apps, .sessions]
    }

    /// The section in view: the last whose top has reached `threshold`, or
    /// the first when none has. `tops` is each section's distance from the
    /// top of the scroll view.
    static func active(tops: [ActivitySection: CGFloat], order: [ActivitySection], threshold: CGFloat) -> ActivitySection? {
        var result = order.first
        for section in order {
            guard let top = tops[section] else { continue }
            if top <= threshold { result = section }
        }
        return result
    }
}

/// Where each section is, as the page scrolls. Only `active` is observed, so
/// scrolling redraws the bar and nothing else.
@MainActor @Observable
final class ActivitySectionTracker {
    private(set) var active: ActivitySection?
    @ObservationIgnored private var tops: [ActivitySection: CGFloat] = [:]
    /// The sections the page shows now. One that has gone is forgotten; one
    /// scrolled out of a lazy list keeps the last place it reported.
    @ObservationIgnored var order: [ActivitySection] = ActivitySection.shown(for: .today) {
        didSet {
            guard order != oldValue else { return }
            tops = tops.filter { order.contains($0.key) }
            refresh()
        }
    }

    /// How far below the top edge a section counts as the one in view.
    static let threshold: CGFloat = 80

    func update(_ section: ActivitySection, top: CGFloat) {
        tops[section] = top
        refresh()
    }

    /// A tap names the section at once, before the scroll has finished.
    func choose(_ section: ActivitySection) {
        if active != section { active = section }
    }

    private func refresh() {
        let next = ActivitySection.active(tops: tops, order: order, threshold: Self.threshold)
        if next != active { active = next }
    }
}

extension View {
    /// Marks the top of a section: what the bar scrolls to, and what it
    /// watches.
    func activitySectionAnchor(_ section: ActivitySection, tracker: ActivitySectionTracker) -> some View {
        self
            .id(section)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).minY } action: { top in
                tracker.update(section, top: top)
            }
    }
}

struct ActivitySectionBar: View {
    let sections: [ActivitySection]
    let tracker: ActivitySectionTracker
    let jump: (ActivitySection) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(sections) { section in
                    let on = tracker.active == section
                    Button { jump(section) } label: {
                        Text(section.title)
                            .font(.solanum(.label, weight: .medium))
                            .foregroundStyle(on ? Solanum.ink : Solanum.inkMuted)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 24)
                            .background {
                                if on {
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(Solanum.segmentOn)
                                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Solanum.hairline))
                                }
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Jump to \(section.title)")
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(Solanum.page)
        .overlay(alignment: .bottom) { Rectangle().fill(Solanum.hairline).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }
}
