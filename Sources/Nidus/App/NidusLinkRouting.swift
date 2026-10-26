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
        if url.scheme?.lowercased() == "nidus", url.host?.lowercased() == "brick" {
            if let signal = BrickSignal.parse(url) { brickCompanion.receive(signal) }
            return
        }
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
        case .save(let url, let token):
            saveFromLink(url: url, token: token)
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

    /// Save for later, from the block page. It puts the address in the inbox
    /// and does nothing else: no snooze, no unblock, no opening the address,
    /// no change to the session (a strict one included). A link without the
    /// block page's token is ignored. The log never holds the address or the
    /// token.
    private func saveFromLink(url: String, token: String) {
        guard let inbox else {
            host?.log.notice("ignored save link: no inbox")
            return
        }
        switch inbox.saveFromBlockPage(url: url, token: token) {
        case .saved: host?.log.debug("saved a page for later")
        case .duplicate: host?.log.debug("save link: already in the inbox")
        case .badToken: host?.log.notice("ignored save link: not from the block page")
        case .notAWebAddress: host?.log.notice("ignored save link: not a web address")
        }
    }

    private func startFromLink(_ start: NidusLink.Start) {
        // A saved setup first, then the link's own parameters over it; the
        // same rules as Shortcuts and the JSON command (FocusOutside.swift).
        switch outsideRequest(start, fromLink: true) {
        case .failure(.setupNotFound):
            host?.log.notice("ignored start link: no setup by that name or id")
        case .failure(.setupAmbiguous):
            host?.log.notice("ignored start link: more than one setup has that name")
        case .failure(.noMatchingCategory):
            let names = (start.categories ?? []).joined(separator: ", ")
            host?.log.notice("ignored start link: no category matches \(names, privacy: .public)")
        case .success(let resolved):
            if !resolved.unmatched.isEmpty {
                host?.log.notice("start link: no category matches \(resolved.unmatched.joined(separator: ", "), privacy: .public)")
            }
            let request = resolved.request
            switch startFromOutside(request) {
            case .started: break
            case .busy: host?.log.notice("ignored start link: a session or break is already on")
            case .nothingToBlock: host?.log.notice("ignored start link: nothing to block")
            case .notReady: host?.log.notice("ignored start link: not ready")
            }
        }
    }
}
