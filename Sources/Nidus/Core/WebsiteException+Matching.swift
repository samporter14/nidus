//
//  WebsiteException+Matching.swift
//  Nidus
//
//  Website exceptions: pages let through although a broader rule in the block
//  list covers them (one research video on a blocked video site). This file
//  is the one place that says how an exception is read, shown and matched.
//
//  Two kinds, both on one exact host:
//
//  - exact: this page only. Same host, same path (nothing below it), and
//    every query parameter the exception names, with the same value:
//    `youtube.com/watch?v=abc` lets `/watch?v=abc&t=30s` through and neither
//    `/watch?v=xyz` nor `/watch`. Parameters the exception doesn't name are
//    ignored.
//  - subtree: this path and everything below it. The query is not used.
//
//  The rules, so they are decided once:
//
//  - Host: lowercase, one leading `www.` and one trailing dot dropped, and
//    compared whole. `youtube.com` does not cover `m.youtube.com` (that
//    exception has to say so), `notyoutube.com`, `youtube.com.evil.example`,
//    or an address with a login in it (`youtube.com@evil.example`, whose host
//    is the part after the `@`). A page that carries a login is never let
//    through at all.
//  - Port: kept when it is not the standard one (80 or 443), and must be the
//    same. Blocking rules ignore ports; exceptions don't, since a different
//    port is a different server.
//  - Encoding: percent-encoding is undone once before comparing, in paths
//    and in queries, so `%73` is `s`. An encoded slash stays inside its
//    segment (`a%2Fb` is one segment, not `a/b`), and a second layer of
//    encoding stays encoded. A query reads `+` as a space.
//  - Case: the host is case-insensitive. Paths and query parameters are not:
//    a blocking rule folds case because that errs toward blocking, and an
//    exception that folded it would err toward letting something through
//    (`v=AbC` and `v=abc` are different videos).
//  - Bytes: text is compared as bytes, so two spellings that merely look the
//    same (a precomposed é and an e with an accent) are different.
//  - Schemes: http and https only, and the exception doesn't say which.
//  - A fragment (`#t=30`) never reaches the server and is never compared.
//  - Where the same parameter appears twice (`v=abc&v=xyz`) every copy must
//    carry the required value, since a server may read either.
//
//  Exceptions apply in block mode only. `WebsiteRule` holds none in allow
//  mode, which already says what is let through.
//

import Foundation

// MARK: - A page

/// A tab's address as an exception sees it: more than `WebLocation`, which
/// leaves out the port and the query.
struct WebPage: Sendable, Hashable {
    let host: String
    /// nil for the standard port of the page's scheme.
    let port: Int?
    /// Decoded, with case kept.
    let segments: [String]
    /// In the order they appear, repeats included.
    let parameters: [WebsiteExceptionRule.Parameter]

    /// nil for anything that is not an http or https page, and for one that
    /// carries a login (`user@host`): a browser drops it, and what the
    /// address says it is cannot be trusted.
    init?(_ url: String) {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              components.user == nil, components.password == nil,
              let rawHost = components.host?.lowercased() else { return nil }
        guard let host = WebsiteExceptionRule.normalized(host: rawHost) else { return nil }
        self.host = host
        let standard = scheme == "https" ? 443 : 80
        port = components.port.flatMap { $0 == standard ? nil : $0 }
        segments = WebsiteEntry.segments(ofPath: components.percentEncodedPath, foldingCase: false)
        parameters = WebsiteExceptionRule.parameters(inQuery: components.percentEncodedQuery)
    }
}

// MARK: - One exception, read

/// A `WebsiteException` read into its parts. `init?(_:)` is how a saved one
/// is read; `WebsiteException.draft(from:kind:)` is how a typed or pasted
/// address becomes one.
struct WebsiteExceptionRule: Sendable, Hashable {
    /// A query parameter, decoded.
    struct Parameter: Sendable, Hashable, Comparable {
        let name: String
        let value: String

        static func < (a: Parameter, b: Parameter) -> Bool {
            (a.name, a.value) < (b.name, b.value)
        }
    }

    let kind: WebsiteException.Kind
    /// Lowercase, without `www.` or a trailing dot.
    let host: String
    /// nil for the standard ports.
    let port: Int?
    /// Decoded, with case kept, and with the few characters that would break
    /// an address apart (`/`, `?`, `#`, `%`, whitespace) still escaped.
    let segments: [String]
    /// What an exact exception requires; always empty for a subtree.
    /// Sorted and without repeats.
    let parameters: [Parameter]

    /// The exception in its one written form: no scheme, no `www.`, no
    /// tracking parameters, no fragment. "youtube.com/watch?v=abc".
    var address: String {
        var text = host
        if let port { text += ":\(port)" }
        text += segments.map { "/" + $0 }.joined()
        if !parameters.isEmpty {
            text += "?" + parameters.map { Self.escapeQuery($0.name) + "=" + Self.escapeQuery($0.value) }.joined(separator: "&")
        }
        return text
    }

    /// The saved form, ready to put in a category or a plan.
    var exception: WebsiteException { WebsiteException(kind: kind, address: address) }

    /// A saved exception read back, or nil when its address is not a usable
    /// web address (it then lets nothing through).
    init?(_ exception: WebsiteException) {
        guard case .success(let draft) = Self.read(exception.address, kind: exception.kind) else { return nil }
        self = draft.rule
    }

    fileprivate init(kind: WebsiteException.Kind, host: String, port: Int?, segments: [String], parameters: [Parameter]) {
        self.kind = kind
        self.host = host
        self.port = port
        self.segments = segments
        self.parameters = parameters
    }

    /// Whether this exception lets the page through.
    func allows(_ page: WebPage) -> Bool {
        guard Self.same(page.host, host), page.port == port else { return false }
        switch kind {
        case .exact:
            guard Self.same(page.segments, segments) else { return false }
            // Every parameter the exception names, and every copy of it.
            return parameters.allSatisfy { required in
                let found = page.parameters.filter { Self.same($0.name, required.name) }
                return !found.isEmpty && found.allSatisfy { Self.same($0.value, required.value) }
            }
        case .subtree:
            return page.segments.count >= segments.count && Self.same(Array(page.segments.prefix(segments.count)), segments)
        }
    }

    /// Whether any of these website rules blocks something this exception
    /// lets through. When none does, the exception changes nothing.
    ///
    /// A rule covers a host and its subdomains and a path and what is below
    /// it. An exact exception does something when its page is covered; a
    /// subtree one also when it sits above a rule's path (`youtube.com`
    /// lets through the `youtube.com/shorts` rule's pages, on that host).
    func isReachable(by websites: [String]) -> Bool {
        let lowered = segments.map { $0.lowercased() }
        return websites.compactMap { WebsiteEntry(stored: $0) }.contains { entry in
            guard host == entry.host || host.hasSuffix("." + entry.host) else { return false }
            switch kind {
            case .exact: return lowered.starts(with: entry.segments)
            case .subtree: return lowered.starts(with: entry.segments) || entry.segments.starts(with: lowered)
            }
        }
    }

    // MARK: Reading an address

    /// A host as exceptions compare it: one trailing dot and one leading
    /// `www.` dropped. nil for what is not a plausible host name.
    static func normalized(host raw: String) -> String? {
        var host = raw
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www."), host.dropFirst(4).contains(".") { host.removeFirst(4) }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        return host
    }

    /// The parameters of a query as written by a browser, decoded: `&`
    /// between them, the first `=` inside one, `+` a space.
    static func parameters(inQuery query: String?) -> [Parameter] {
        guard let query, !query.isEmpty else { return [] }
        return query.split(separator: "&", omittingEmptySubsequences: true).map { piece in
            guard let equals = piece.firstIndex(of: "=") else { return Parameter(name: decode(piece), value: "") }
            return Parameter(name: decode(piece[..<equals]), value: decode(piece[piece.index(after: equals)...]))
        }
    }

    private static func decode(_ text: Substring) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    /// Text compared as bytes: no case folding, no Unicode equivalence.
    static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
    static func same(_ a: [String], _ b: [String]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { same($0, $1) }
    }

    /// Parameters that say where you came from or how far into a video you
    /// were, not which page it is. Dropped from an address when an exception
    /// is made, and said so. Names compare without regard to case.
    static let noiseNames: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "twclid", "yclid", "igshid",
        "mc_cid", "mc_eid", "mkt_tok", "_ga", "_gl", "_hsenc", "_hsmi", "spm",
        "si", "t", "feature", "pp", "ab_channel", "time_continue", "ref_src", "ref_url",
    ]

    static func isNoise(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.hasPrefix("utm_") || noiseNames.contains(lowered)
    }

    /// A query name or value written so that `&`, `=`, `+`, `%`, `?`, `#` and
    /// whitespace can't break the address apart; letters of any script stay
    /// readable. (The path's segments are already written this way by
    /// `WebsiteEntry.segments`.)
    private static func escapeQuery(_ text: String) -> String {
        let breaking = CharacterSet(charactersIn: "%&=+?#")
            .union(.whitespacesAndNewlines).union(.controlCharacters)
        var result = ""
        for scalar in text.unicodeScalars {
            if breaking.contains(scalar) {
                for byte in String(scalar).utf8 { result += String(format: "%%%02X", byte) }
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    fileprivate static func read(_ input: String, kind: WebsiteException.Kind) -> Result<WebsiteExceptionDraft, WebsiteExceptionProblem> {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        // Web addresses only; any other scheme is not one.
        if let scheme = text.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*://"#, options: .regularExpression) {
            guard ["http://", "https://"].contains(text[scheme].lowercased()) else { return .failure(.notAWebAddress) }
            text.removeSubrange(scheme)
        } else if text.hasPrefix("//") {
            text.removeFirst(2)
        }
        var fragment: String?
        if let hash = text.firstIndex(of: "#") {
            fragment = String(text[text.index(after: hash)...])
            text = String(text[..<hash])
        }
        var query: String?
        if let mark = text.firstIndex(of: "?") {
            query = String(text[text.index(after: mark)...])
            text = String(text[..<mark])
        }
        let slash = text.firstIndex(of: "/")
        var authority = String(slash.map { text[..<$0] } ?? text[...])
        let path = slash.map { String(text[$0...]) } ?? ""

        // `name@host` is a login; the host is the part after it, and which
        // one a person meant is not for us to guess.
        guard !authority.contains("@") else { return .failure(.notAWebAddress) }
        var port: Int?
        if let colon = authority.lastIndex(of: ":") {
            let digits = authority[authority.index(after: colon)...]
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(digits), (1...65535).contains(number) else { return .failure(.notAWebAddress) }
            port = number == 80 || number == 443 ? nil : number
            authority = String(authority[..<colon])
        }
        if authority.hasSuffix(".") { authority.removeLast() }
        // The host goes through the same reading as a blocking rule's, so a
        // name typed with accents and the form a browser reports agree.
        guard let entry = WebsiteEntry(typed: authority), let host = normalized(host: entry.host) else {
            return .failure(.notAWebAddress)
        }

        let segments = WebsiteEntry.segments(ofPath: path, foldingCase: false)
        var named: [Parameter] = []
        var ignored: [Parameter] = []
        for parameter in parameters(inQuery: query) {
            if isNoise(parameter.name) {
                if !ignored.contains(parameter) { ignored.append(parameter) }
            } else if !named.contains(parameter) {
                named.append(parameter)
            }
        }

        switch kind {
        case .exact:
            // The same name with two values can never be met by one page.
            if let clash = Dictionary(grouping: named, by: \.name).first(where: { $0.value.count > 1 }) {
                return .failure(.conflictingParameter(clash.key))
            }
            let rule = WebsiteExceptionRule(kind: kind, host: host, port: port, segments: segments, parameters: named.sorted())
            return .success(WebsiteExceptionDraft(rule: rule, ignored: ignored, unused: [], sawQuery: query?.isEmpty == false,
                                                  fragment: fragment))
        case .subtree:
            let rule = WebsiteExceptionRule(kind: kind, host: host, port: port, segments: segments, parameters: [])
            return .success(WebsiteExceptionDraft(rule: rule, ignored: ignored, unused: named.sorted(), sawQuery: query?.isEmpty == false,
                                                  fragment: fragment))
        }
    }
}

// MARK: - Making one

enum WebsiteExceptionProblem: Error, Equatable, Sendable {
    case empty
    case notAWebAddress
    case conflictingParameter(String)

    /// Plain words for the person who typed it. Nothing for an empty field.
    var message: String? {
        switch self {
        case .empty: return nil
        case .notAWebAddress: return "That isn\u{2019}t a web address. Use a page like example.com/page (http or https)."
        case .conflictingParameter(let name): return "The address gives \u{201C}\(name)\u{201D} two different values, so no page could match it."
        }
    }
}

/// A typed or pasted address, read, with exactly what it would let through
/// written out before anything is saved.
struct WebsiteExceptionDraft: Sendable, Equatable {
    let rule: WebsiteExceptionRule
    /// Tracking and position parameters that were in the address and are
    /// not part of the exception.
    let ignored: [WebsiteExceptionRule.Parameter]
    /// Parameters a subtree exception does not use (the identifying kind).
    let unused: [WebsiteExceptionRule.Parameter]
    fileprivate let sawQuery: Bool
    fileprivate let fragment: String?

    /// What to save.
    var exception: WebsiteException { rule.exception }

    var host: String { rule.host }

    /// "Only youtube.com/watch?v=abc".
    var permits: String {
        let address = rule.address
        switch rule.kind {
        case .exact:
            return rule.parameters.isEmpty
                ? "Only \(address), with any ?parameters"
                : "Only \(address)"
        case .subtree:
            return rule.segments.isEmpty ? "All of \(address)" : "Everything at \(address) and below"
        }
    }

    /// The whole sentence the person reads before adding it: what is let
    /// through, and what stays blocked.
    var summary: String {
        if rule.kind == .subtree, rule.segments.isEmpty {
            return permits + ". Subdomains like m.\(rule.host) stay blocked."
        }
        return permits + ". The rest of \(rule.host) stays blocked."
    }

    /// What is required, as the address would have to carry it ("v=abc"),
    /// or nil when no parameter is.
    var requirement: String? {
        rule.parameters.isEmpty ? nil : rule.parameters.map { $0.name + "=" + $0.value }.joined(separator: ", ")
    }

    /// Lines that say, without jargon, what else was decided.
    var details: [String] {
        var lines: [String] = []
        if let requirement {
            lines.append("The address must have \(requirement). Other parameters are ignored.")
        }
        if !ignored.isEmpty {
            let names = ignored.map(\.name).joined(separator: ", ")
            lines.append("Left out as tracking or position: \(names).")
        }
        lines.append("Only on \(rule.host) and www.\(rule.host), not other subdomains.")
        return lines
    }

    /// Things worth a second look: what the exception lets through is
    /// broader than the address may suggest.
    var warnings: [String] {
        var lines: [String] = []
        if !unused.isEmpty {
            let list = unused.map { $0.name + "=" + $0.value }.joined(separator: ", ")
            lines.append("\u{201C}This page and below\u{201D} doesn\u{2019}t use \(list), so it lets through every page under \(rule.address). Choose \u{201C}Only this page\u{201D} to keep it.")
        }
        if rule.kind == .exact, rule.parameters.isEmpty, sawQuery {
            lines.append("Nothing after the ? identifies the page, so any page at this path is let through.")
        }
        if let fragment, fragment.hasPrefix("/") || fragment.hasPrefix("!") {
            lines.append("This site keeps its page after the #, which Nidus can\u{2019}t see, so it lets through every page of it at this address.")
        }
        return lines
    }

    /// Whether any of these websites blocks something this lets through.
    func isReachable(by websites: [String]) -> Bool { rule.isReachable(by: websites) }
}

extension WebsiteException {
    /// A typed or pasted address read as an exception of this kind, with
    /// tracking parameters left out. The one way an exception is made, so
    /// what is saved is what was shown.
    static func draft(from input: String, kind: Kind) -> Result<WebsiteExceptionDraft, WebsiteExceptionProblem> {
        WebsiteExceptionRule.read(input, kind: kind)
    }

    /// This exception read, or nil when its address is not a usable one.
    var rule: WebsiteExceptionRule? { WebsiteExceptionRule(self) }

    /// How the person reads it in a list: its address.
    var displayAddress: String { rule?.address ?? address }

    /// "Only this page" or "This page and below".
    var kindTitle: String { kind.title }

    /// Whether any of these websites blocks something it lets through.
    func isReachable(by websites: [String]) -> Bool { rule?.isReachable(by: websites) ?? false }
}

extension WebsiteException.Kind {
    var title: String {
        switch self {
        case .exact: return "Only this page"
        case .subtree: return "This page and below"
        }
    }

    static let choices: [WebsiteException.Kind] = [.exact, .subtree]
}

// MARK: - Matching

/// A list of exceptions, read once. Stateless, like the rule that holds it:
/// every URL is judged on its own, so a tab that was allowed at one address
/// and redirects to another is judged again at the second.
struct WebsiteExceptionMatcher: Sendable {
    private let rules: [WebsiteExceptionRule]

    init(_ exceptions: [WebsiteException]) {
        rules = exceptions.compactMap { WebsiteExceptionRule($0) }
    }

    var isEmpty: Bool { rules.isEmpty }

    func allows(_ url: String) -> Bool {
        guard !rules.isEmpty, let page = WebPage(url) else { return false }
        return rules.contains { $0.allows(page) }
    }
}

// MARK: - A running session's rule

extension WebsiteRule {
    /// The rule a running session enforces: what its engine says is blocked
    /// now, the sites snoozed, and the exceptions its plan carries. They come
    /// from the plan, which was fixed when the session started, so editing a
    /// category (or anything else) mid-session changes nothing until the
    /// next one. Block mode only; an allow list has none.
    init(enforcement: Enforcement, session: SessionState?) {
        // Snoozed sites on the plan, so a snooze covers a listed entry that
        // overlaps another (`youtube.com/shorts` inside `youtube.com`).
        let snoozed = session.map { Set($0.snoozes.keys).intersection($0.plan.websites) } ?? []
        let mode: Mode = enforcement.mode == .block ? .block : .allow
        self.init(mode: mode, domains: Array(enforcement.websites), snoozed: Array(snoozed),
                  exceptions: mode == .block ? session?.plan.websiteExceptions ?? [] : [])
    }
}
