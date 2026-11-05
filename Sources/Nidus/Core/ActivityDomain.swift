//
//  ActivityDomain.swift
//  Nidus
//
//  Turns a selected tab's URL into the one thing all-day activity keeps of
//  it: the site's domain. Scheme, credentials, port, path, query and fragment
//  are gone by the time this returns, and a local or unnamed address gives
//  nothing at all. Works from the host alone, so no list is downloaded.
//

import Foundation

enum ActivityDomain {
    /// Hosts that are each a separate site under a shared domain. Keeping
    /// only the shared part would merge strangers' sites into one row.
    private static let sharedHosting: Set<String> = [
        "github.io", "gitlab.io", "pages.dev", "netlify.app", "vercel.app", "web.app",
        "firebaseapp.com", "herokuapp.com", "cloudfront.net", "azurewebsites.net",
        "blogspot.com", "wordpress.com", "substack.com", "notion.site", "readthedocs.io",
    ]
    /// Under these, the institute is the useful part, and the host says
    /// nothing about a person (pubmed.ncbi.nlm.nih.gov, not nih.gov).
    private static let fullHostSuffixes = ["nih.gov"]
    /// Second-level labels that a country uses as a public suffix: co.uk,
    /// ac.jp, com.au, edu.cn and so on.
    private static let countrySecondLevel: Set<String> = [
        "ac", "co", "com", "edu", "go", "gob", "gov", "gouv", "govt", "ne", "net", "or", "org",
    ]
    private static let localSuffixes = ["local", "localhost", "internal", "lan", "home", "intranet", "test", "invalid"]

    /// The site of an http or https URL, or nil when it has none worth
    /// keeping: another scheme, an IP address, or a machine on a local network.
    static func site(from rawURL: String) -> String? {
        guard let parts = URLComponents(string: rawURL),
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var host = parts.host?.lowercased() else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        guard isDomain(host) else { return nil }
        return registrable(host)
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

    /// The part of a host someone would register, so a workspace or account
    /// name in a subdomain (lab-name.slack.com) stays out of the record.
    static func registrable(_ host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        if let suffix = fullHostSuffixes.first(where: { host == $0 || host.hasSuffix("." + $0) }), host != suffix {
            return labels.first == "www" ? labels.dropFirst().joined(separator: ".") : host
        }
        guard labels.count > 2 else { return host }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        let tld = labels[labels.count - 1], second = labels[labels.count - 2]
        let keeps = sharedHosting.contains(lastTwo) || (tld.count == 2 && countrySecondLevel.contains(second)) ? 3 : 2
        return labels.suffix(keeps).joined(separator: ".")
    }
}
