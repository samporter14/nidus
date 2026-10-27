import SwiftUI

/// A small value made from the same resolution as Start. It never reads the
/// calendar, spends the meeting choice, opens resources or starts a session.
struct SessionPreview: Equatable {
    struct Detail: Equatable {
        var symbol: String
        var text: String
    }

    var summary: String
    var details: [Detail]

    init(plan: SessionPlan, categoryNames: [String]) {
        let length = plan.duration.map { FocusFormat.duration(minutes: Int($0 / 60)) } ?? "Open-ended"
        let names = categoryNames.prefix(2).joined(separator: " + ")
            + (categoryNames.count > 2 ? " + \(categoryNames.count - 2) more" : "")
        let scope = names.isEmpty ? (plan.mode == .allow ? "Allow list" : "Block list")
            : (plan.mode == .allow ? "Only \(names) allowed" : "\(names) blocked")
        // An open-ended session ends by hand, so it has no automatic break.
        let rest = plan.duration == nil ? 0 : Int((plan.breakLength ?? 0) / 60)
        summary = [length, scope, rest > 0 ? "\(rest) min break" : nil].compactMap { $0 }.joined(separator: " · ")
        let rules = Self.counts(apps: plan.apps.count, sites: plan.websites.count)
        details = [.init(symbol: plan.mode == .allow ? "checkmark.shield" : "nosign",
                         text: "\(plan.mode == .allow ? "Allow list" : "Block list"): \(rules).")]
        if categoryNames.count > 2 {
            details.append(.init(symbol: "square.stack", text: categoryNames.joined(separator: ", ")))
        }
        if !plan.websiteExceptions.isEmpty {
            let count = plan.websiteExceptions.count
            details.append(.init(symbol: "link", text: "\(count) website \(count == 1 ? "exception" : "exceptions")."))
        }
        if plan.strict {
            details.append(.init(symbol: NidusSymbols.strict, text: "Strict: no pause or snooze. Ending early requires the confirmation phrase."))
        }
        if rest > 0 {
            let rules = plan.breakRules ?? BreakRules()
            details.append(.init(symbol: NidusSymbols.rest,
                                 text: rules.isUnrestricted ? "Nothing stays blocked during the break."
                                 : "Break block list: \(Self.counts(apps: rules.apps.count, sites: rules.websites.count))."))
            if let reminder = rules.displayReminder { details.append(.init(symbol: "text.bubble", text: reminder)) }
        }
        if !plan.launchApps.isEmpty {
            let count = plan.launchApps.count
            details.append(.init(symbol: "app", text: "Opens \(count) \(count == 1 ? "app" : "apps") when focus starts."))
        }
        if !plan.resources.isEmpty {
            details.append(.init(symbol: "doc", text: "Opens \(plan.resources.count) saved workspace \(plan.resources.count == 1 ? "item" : "items")."))
        }
        if let shortcut = plan.startShortcut { details.append(.init(symbol: NidusSymbols.setup, text: "At start: \(shortcut)")) }
        if let shortcut = plan.endShortcut { details.append(.init(symbol: NidusSymbols.setup, text: "At end: \(shortcut)")) }
    }

    private static func counts(apps: Int, sites: Int) -> String {
        "\(apps) \(apps == 1 ? "app" : "apps") · \(sites) \(sites == 1 ? "website" : "websites")"
    }
}

extension NidusModel {
    func sessionPreview(now: Date = Date()) -> SessionPreview? {
        let request = popoverRequest(now: now)
        // Cached meeting only. Start still refreshes the real calendar once
        // at the moment of committing, as it always has.
        let meeting = meetings.isChosen ? meetings.offeredMinutes(now: now) : nil
        guard let resolved = request.resolved(with: startDefaults, length: {
            (meeting ?? minutesForNextStart(now: now), meeting != nil)
        }) else { return nil }
        return SessionPreview(plan: resolved.plan, categoryNames: selectedCategories.filter { !$0.isEmpty }.map(\.name))
    }
}

struct SessionPreviewRow: View {
    let preview: SessionPreview
    @State private var expanded = false

    init(preview: SessionPreview, expanded: Bool = false) {
        self.preview = preview
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            // Details have no hosting tree until the person asks for them.
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(preview.details.indices, id: \.self) { index in
                        let detail = preview.details[index]
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: detail.symbol).frame(width: 14).accessibilityHidden(true)
                            Text(verbatim: detail.text).fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 6)
            }
        } label: {
            Text(verbatim: preview.summary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .foregroundStyle(Solanum.inkMuted)
        .tint(Solanum.clayText)
        .help("Review this session’s rules, break and actions")
    }
}
