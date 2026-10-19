//
//  ActivityProbe.swift
//  Nidus
//
//  Reads metadata from the foreground app only. URL and title values are
//  transient: callers receive a recognized service label and, if requested,
//  a short selected-page/document title. No page or document text is read.
//

import AppKit
import ApplicationServices

struct ActivityDetail: Sendable, Equatable {
    var site: String?
    var title: String?
}

enum ActivityProbe {
    static let capsidID = "local.sam.bench"
    static let wordID = "com.microsoft.Word"
    static let claudeID = "com.anthropic.claudefordesktop"
    static let scienceID = "com.anthropic.operon"
    static let scienceWebAppID = "com.apple.Safari.WebApp.67246384-D749-4D50-B379-1C4A27B67E88"

    static func needsProbe(_ bundleID: String, titles: Bool) -> Bool {
        if BrowserProfile.known.contains(where: { $0.bundleID == bundleID }) { return true }
        return titles && (bundleID == capsidID || bundleID == wordID || bundleID == claudeID || bundleID == scienceID || bundleID == scienceWebAppID)
    }

    /// Safe to call on a utility queue. Apple Events have a short timeout and
    /// never ask for consent here. AX reads only the focused window's title.
    static func detail(bundleID: String, pid: pid_t, titles: Bool) -> ActivityDetail? {
        if let browser = BrowserProfile.known.first(where: { $0.bundleID == bundleID }) {
            return selectedTab(in: browser, pid: pid, titles: titles)
        }
        switch bundleID {
        case capsidID:
            return titles ? CapsidActivityContext.read(pid: pid) : nil
        case wordID:
            return ActivityDetail(site: nil, title: titles ? usefulWindowTitle(pid: pid) : nil)
        case claudeID:
            return ActivityDetail(site: nil, title: titles ? usefulWindowTitle(pid: pid) : nil)
        case scienceID, scienceWebAppID:
            return ActivityDetail(site: nil, title: titles ? usefulWindowTitle(pid: pid) : nil)
        default:
            return nil
        }
    }

    /// Recognition takes place before any tab title is requested or retained.
    static func service(for rawURL: String) -> String? {
        guard let parts = URLComponents(string: rawURL),
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = parts.host?.lowercased() else { return nil }
        if host == "docs.google.com", parts.path.hasPrefix("/document/") { return "Google Docs" }
        if host == "claude.ai" || host == "www.claude.ai" { return "Claude" }
        if host == "word.office.com" || host == "word.cloud.microsoft" { return "Microsoft Word" }
        return nil
    }

    /// Machine-local Science origin; never treats arbitrary localhost tools as Science.
    static func isLocalScienceURL(_ raw: String) -> Bool {
        guard let u = URLComponents(string: raw), u.scheme == "http",
              ["localhost", "127.0.0.1", "[::1]", "::1"].contains(u.host?.lowercased() ?? ""),
              u.port == 8765, u.user == nil, u.password == nil else { return false }
        let pieces = u.path.split(separator: "/")
        if pieces.isEmpty { return true }
        guard pieces.count == 2 || pieces.count == 4,
              pieces[0] == "projects", pieces[1].hasPrefix("proj_"), pieces[1].count > 5 else { return false }
        return pieces.count == 2 || (pieces[2] == "frames" && UUID(uuidString: String(pieces[3])) != nil)
    }

    private static func selectedTab(in browser: BrowserProfile, pid: pid_t, titles: Bool) -> ActivityDetail? {
        let target = AppleEventTarget(processIdentifier: pid)
        guard target.automationPermission(ask: false) == nil else { return nil }
        let window = ObjectSpecifier.index("cwin", 1)
        let tab = ObjectSpecifier.property(browser.bundleID == BrowserProfile.safari.bundleID ? "cTab" : "acTa", of: window)
        let rawURL = try? target.get(ObjectSpecifier.property(browser.urlProperty, of: tab), timeout: 0.75).stringValue
        guard let rawURL else { return nil }
        // The local Science launcher serves its UI in a separate browser.
        // A loopback address alone is not enough: require the running launcher,
        // its exact port/routes, and the application's generic tab title.
        if isLocalScienceURL(rawURL) {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: scienceID).isEmpty else { return nil }
            let label = try? target.get(ObjectSpecifier.property("pnam", of: tab), timeout: 0.75).stringValue
            guard label == "Claude Science" else { return nil }
            let confirmed = try? target.get(ObjectSpecifier.property(browser.urlProperty, of: tab), timeout: 0.75).stringValue
            guard confirmed == rawURL else { return nil }
            return ActivityDetail(site: "Claude Science", title: nil)
        }
        guard let site = service(for: rawURL) else { return nil }
        guard titles else { return ActivityDetail(site: site, title: nil) }
        let rawTitle = try? target.get(ObjectSpecifier.property("pnam", of: tab), timeout: 0.75).stringValue
        // The selected tab may change between two Apple Events. A title from
        // a different tab must never inherit the first tab's trusted service.
        let confirmedURL = try? target.get(ObjectSpecifier.property(browser.urlProperty, of: tab), timeout: 0.75).stringValue
        guard confirmedURL == rawURL else { return nil }
        return ActivityDetail(site: site, title: cleanTitle(rawTitle))
    }

    private static func usefulWindowTitle(pid: pid_t) -> String? {
        usefulTitle(windowTitle(pid: pid))
    }

    static func usefulTitle(_ raw: String?) -> String? {
        guard let title = cleanTitle(raw) else { return nil }
        let generic: Set<String> = ["claude", "claude science", "microsoft word", "word", "settings",
                                    "preferences", "open", "save", "open document", "save as"]
        return generic.contains(title.lowercased()) ? nil : title
    }

    private static func windowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.75)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let window = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.75)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success else { return nil }
        return cleanTitle(value as? String)
    }

    static func cleanTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let clean = raw.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        let words = clean.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let title = String(words.joined(separator: " ").prefix(160))
        guard !title.isEmpty, !title.contains("://"), !title.lowercased().hasPrefix("www.") else { return nil }
        return title
    }
}
