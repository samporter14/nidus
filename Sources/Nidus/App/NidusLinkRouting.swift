//
//  NidusLinkRouting.swift
//  Nidus
//
//  Carries a parsed nidus:// link out. NidusLink.swift reads it; the commands
//  it calls are FocusOutside.swift's, shared with Shortcuts.
//

import SwiftUI

// MARK: - Links

extension NidusModel {
    /// A nidus:// link: from the block page's Snooze, or any other app, page
    /// or Shortcut. Anything unreadable is ignored and logged without its
    /// values, the goal being the user's own words.
    func handle(_ url: URL) {
        switch NidusLink.parse(url) {
        case .success(let link):
            route(link)
        case .failure(let rejection):
            host?.log.notice("ignored link: \(rejection.description, privacy: .public)")
        }
    }

    func route(_ link: NidusLink) {
        switch link {
        case .snooze(let site):
            // Only during a session: a stale block page's Snooze does nothing.
            guard isActive else {
                host?.log.debug("ignored snooze outside a session")
                return
            }
            // Through the pause, if one is set: the page can't skip it.
            requestSnooze(site)
        case .start(let start):
            startFromLink(start)
        case .end:
            endFromOutside()
        case .toggle:
            toggleFromOutside()
        case .popover:
            showPopover()
        }
    }

    private func startFromLink(_ start: NidusLink.Start) {
        // PRESET HOOK: `nidus://start?preset=…` is applied here, before the
        // link's own parameters (see NidusLink.Start). Nothing reads it yet.
        switch start.resolve(against: categories) {
        case .failure(let failure):
            let names = failure.asked.joined(separator: ", ")
            host?.log.notice("ignored start link: no category matches \(names, privacy: .public)")
        case .success(let resolved):
            if !resolved.unmatched.isEmpty {
                host?.log.notice("start link: no category matches \(resolved.unmatched.joined(separator: ", "), privacy: .public)")
            }
            switch startFromOutside(resolved.request) {
            case .started: break
            case .busy: host?.log.notice("ignored start link: a session or break is already on")
            case .nothingToBlock: host?.log.notice("ignored start link: nothing to block")
            case .notReady: host?.log.notice("ignored start link: not ready")
            }
        }
    }
}
