//
//  ActivityProbe.swift
//  Nidus
//
//  Reads metadata from the foreground app only: a recognized service label,
//  the site's domain and address, and the selected tab's or focused window's
//  title. No page or document text is read.
//

import AppKit
import ApplicationServices

struct ActivityDetail: Sendable, Equatable {
    /// A recognized service label, such as Google Docs.
    var site: String?
    var title: String?
    /// The site's domain, the key websites are counted under.
    var domain: String? = nil
    /// The page's address, for reopening it later. See `keptURL`.
    var url: String? = nil

    /// What a focus session keeps of this. Its record has no addresses.
    var forSession: ActivityDetail { ActivityDetail(site: site ?? domain, title: title) }
}

enum ActivityProbe {
    static let capsidID = "local.sam.bench"
    static let wordID = "com.microsoft.Word"
    static let claudeID = "com.anthropic.claudefordesktop"
    static let scienceID = "com.anthropic.operon"
    static let scienceWebAppID = "com.apple.Safari.WebApp.67246384-D749-4D50-B379-1C4A27B67E88"
    static let previewID = "com.apple.Preview"
    static let acrobatIDs: Set<String> = ["com.adobe.Reader", "com.adobe.Acrobat.Pro"]
    /// Apps whose focused window title names the document. Elsewhere a title
    /// is a folder or a shell prompt, and isn't read.
    static let documentApps: Set<String> = Set([
        wordID, "com.microsoft.Excel", "com.microsoft.Powerpoint",
        "com.apple.iWork.Pages", "com.apple.iWork.Numbers", "com.apple.iWork.Keynote", "com.apple.TextEdit",
        previewID, claudeID, scienceID, scienceWebAppID
    ]).union(acrobatIDs)
    /// Longer than any address worth reopening, and short of a data: blob.
    static let urlLimit = 2048

    static func needsProbe(_ bundleID: String, titles: Bool) -> Bool {
        if BrowserProfile.known.contains(where: { $0.bundleID == bundleID }) { return true }
        return titles && (bundleID == capsidID || documentApps.contains(bundleID))
    }

    /// Safe to call on a utility queue. Apple Events have a short timeout and
    /// never ask for consent here. AX reads only the focused window's title.
    static func detail(bundleID: String, pid: pid_t, titles: Bool) -> ActivityDetail? {
        if let browser = BrowserProfile.known.first(where: { $0.bundleID == bundleID }) {
            return selectedTab(in: browser, pid: pid, titles: titles)
        }
        if bundleID == capsidID { return titles ? CapsidActivityContext.read(pid: pid) : nil }
        guard documentApps.contains(bundleID) else { return nil }
        let title = titles ? usefulTitle(documentTitle(windowTitle(pid: pid), bundleID: bundleID)) : nil
        return ActivityDetail(site: nil, title: title)
    }

    /// An address worth keeping: a web page's, and not an endless one.
    static func keptURL(_ raw: String?) -> String? {
        guard let raw, raw.count <= urlLimit, let scheme = URLComponents(string: raw)?.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return raw
    }

    /// Takes off what changes while the same document stays open: Preview's
    /// page number, and Acrobat's own name.
    static func documentTitle(_ raw: String?, bundleID: String) -> String? {
        guard var title = raw else { return nil }
        if bundleID == previewID,
           let page = title.range(of: #"\s*[\(\-–—]\s*[Pp]age \d+ of \d+\)?\s*$"#, options: .regularExpression) {
            title.removeSubrange(page)
        }
        if acrobatIDs.contains(bundleID),
           let name = title.range(of: #"\s+[\-–—]\s+Adobe Acrobat.*$"#, options: .regularExpression) {
            title.removeSubrange(name)
        }
        return title
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

    /// A page of each service `service(for:)` names, so a stretch saved with
    /// only its label can still be read against website rules. nil for a label
    /// with no public address (the local Science and Capsid tabs).
    static func address(forService label: String) -> String? {
        let page: String
        switch label {
        case "Google Docs": page = "docs.google.com/document/"
        case "Claude": page = "claude.ai/"
        case "Microsoft Word": page = "word.cloud.microsoft/"
        default: return nil
        }
        return "https://" + page
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
        let url = ObjectSpecifier.property(browser.urlProperty, of: tab)
        let name = ObjectSpecifier.property("pnam", of: tab)
        let rawURL = try? target.get(url, timeout: 0.75).stringValue
        guard let rawURL else { return nil }
        // The local Science launcher serves its UI in a separate browser.
        // A loopback address alone is not enough: require the running launcher,
        // its exact port/routes, and the application's generic tab title.
        if isLocalScienceURL(rawURL) {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: scienceID).isEmpty else { return nil }
            let label = try? target.get(name, timeout: 0.75).stringValue
            guard label == "Claude Science" else { return nil }
            let confirmed = try? target.get(url, timeout: 0.75).stringValue
            guard confirmed == rawURL else { return nil }
            return ActivityDetail(site: "Claude Science", title: nil)
        }
        let rawTitle = titles ? (try? target.get(name, timeout: 0.75).stringValue) : nil
        // The selected tab may change between two Apple Events, and a title
        // from a different tab must not be kept under this one's site.
        let confirmedURL = try? target.get(url, timeout: 0.75).stringValue
        guard confirmedURL == rawURL else { return nil }
        return ActivityDetail(site: service(for: rawURL), title: cleanTitle(rawTitle),
                              domain: ActivityDomain.site(from: rawURL), url: keptURL(rawURL))
    }

    static func usefulTitle(_ raw: String?) -> String? {
        guard let title = cleanTitle(raw) else { return nil }
        let generic: Set<String> = ["claude", "claude science", "microsoft word", "word", "settings",
                                    "preferences", "open", "save", "open document", "save as",
                                    "preview", "adobe acrobat", "adobe acrobat reader", "adobe acrobat pro", "home"]
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
        return value as? String
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
