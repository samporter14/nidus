//
//  ActivityDomain.swift
//  Nidus
//
//  The site a selected tab's URL counts under: its host, without a leading
//  "www.", so docs.google.com and scholar.google.com stay apart. A local or
//  unnamed address gives nothing.
//

import Foundation

enum ActivityDomain {
    private static let localSuffixes = ["local", "localhost", "internal", "lan", "home", "intranet", "test", "invalid"]

    /// The site of an http or https URL, or nil when it has none worth
    /// keeping: another scheme, an IP address, or a machine on a local network.
    static func site(from rawURL: String) -> String? {
        guard let parts = URLComponents(string: rawURL),
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var host = parts.host?.lowercased() else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        guard isDomain(host) else { return nil }
        return host.hasPrefix("www.") && isDomain(String(host.dropFirst(4))) ? String(host.dropFirst(4)) : host
    }

    /// Second-level labels that sit under a two-letter country code
    /// (`bbc.co.uk`, `unsw.edu.au`). No public-suffix list ships with the app,
    /// so this short list stands in for it.
    private static let countrySecondLevels: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or", "go", "sch"]

    /// The registrable domain of a host from `site(from:)` (`google.com` for
    /// `docs.google.com`), or nil for a host that is not a domain. A host that
    /// is already registrable gives itself.
    static func registrable(of host: String) -> String? {
        guard isDomain(host) else { return nil }
        let labels = host.split(separator: ".")
        var keep = 2
        if labels.count >= 3, let tld = labels.last, tld.count == 2,
           countrySecondLevels.contains(String(labels[labels.count - 2])) { keep = 3 }
        return labels.suffix(keep).joined(separator: ".")
    }

    /// Whether a string could only be a bare domain: dotted, ASCII, no scheme,
    /// path or port, and not an address. Punycode names pass as written.
    static func isDomain(_ text: String) -> Bool {
        guard text.count <= 253 else { return false }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let last = labels.last, !localSuffixes.contains(String(last)) else { return false }
        // Every dotted IPv4 form ends in digits; no public TLD does.
        guard last.contains(where: \.isLetter) else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.utf8.allSatisfy { byte in
                    (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D
                }
        }
    }
}
