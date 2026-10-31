//
//  ProtectionStatus.swift
//  Nidus
//
//  What a session actually covers right now, in one line: the browsers whose
//  tabs are being watched, those Nidus isn't allowed to control, browsers it
//  can't watch at all (they offer no scripting, or none Nidus has codes
//  for), and blocked apps that wouldn't quit. The popover and the
//  right-click menu show it; a strict session keeps a missing permission in
//  view rather than saying it once.
//
//  Shared by the app and its tests.
//

import Foundation

/// Browsers Nidus can't block websites in, and how to find them.
enum UncoveredBrowsers {
    /// Browsers known to have no tab scripting Nidus can use: Firefox and
    /// Zen offer none, and the rest are not in `BrowserProfile.known`
    /// because their codes were never read from the installed app (see
    /// BrowserBlocker.swift). Any other app that opens web links is found
    /// through Launch Services too; this list only names the common ones
    /// when they aren't the handler.
    static let named: [String: String] = [
        "org.mozilla.firefox": "Firefox",
        "org.mozilla.firefoxdeveloperedition": "Firefox Developer Edition",
        "org.mozilla.nightly": "Firefox Nightly",
        "app.zen-browser.zen": "Zen",
        "com.microsoft.edgemac": "Microsoft Edge",
        "company.thebrowser.Browser": "Arc",
        "company.thebrowser.dia": "Dia",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "com.kagi.kagimacOS": "Orion",
    ]

    /// Link routers: they hand each link to a browser, so they show no
    /// pages of their own and there is nothing to block in them.
    static let linkRouters: Set<String> = [
        "com.sindresorhus.Velja", "com.choosyosx.Choosy", "com.johnste.finicky",
        "com.alexstrnik.Browserosaurus", "com.loshadki.OpenIn",
    ]

    /// Of the apps that open web links (and the named ones), those Nidus
    /// can't watch: not a known browser, not a link router, not Nidus, not
    /// exempt.
    static func uncovered(_ candidates: [String], ownBundleID: String? = Bundle.main.bundleIdentifier) -> [String] {
        let known = Set(BrowserProfile.known.map(\.bundleID))
        var seen = Set<String>()
        return candidates.filter { id in
            !known.contains(id) && !linkRouters.contains(id) && id != ownBundleID
                && !AppBlocker.exempt.contains(id) && seen.insert(id).inserted
        }
    }

    /// The ones a session should offer to block as apps: uncovered, and not
    /// already blocked by it as an app.
    static func toOffer(_ uncovered: [String], blockedAsApp: (String) -> Bool) -> [String] {
        uncovered.filter { !blockedAsApp($0) }
    }
}

struct ProtectionStatus: Equatable, Sendable {
    /// Known browsers running whose tabs are being watched.
    var watched: [String] = []
    /// Known browsers running that Nidus may not control.
    var noPermission: [String] = []
    /// Running browsers Nidus can't watch, and not blocked as apps.
    var unwatched: [String] = []
    /// Blocked apps that are still running after being asked to quit.
    var refused: [String] = []
    /// Whether the session blocks any websites at all.
    var blocksWebsites = true

    /// Nothing is slipping through.
    var isComplete: Bool { noPermission.isEmpty && unwatched.isEmpty && refused.isEmpty }

    /// The line: what's wrong first, else what's covered.
    var line: String {
        var parts: [String] = []
        if blocksWebsites {
            if !noPermission.isEmpty { parts.append("No permission for \(Self.list(noPermission))") }
            if !unwatched.isEmpty { parts.append("Sites not blocked in \(Self.list(unwatched))") }
        }
        if !refused.isEmpty { parts.append("\(Self.list(refused)) wouldn\u{2019}t quit") }
        if !parts.isEmpty { return parts.joined(separator: " \u{00B7} ") }
        guard blocksWebsites else { return "Blocking apps" }
        return watched.isEmpty ? "Sites blocked in any browser you open" : "Sites blocked in \(Self.list(watched))"
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}
