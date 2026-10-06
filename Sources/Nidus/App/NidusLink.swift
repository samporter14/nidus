//
//  NidusLink.swift
//  Nidus
//
//  What a nidus:// link asks for, read without touching the app: the parser
//  is a pure value type so every odd link can be tested. NidusLinkRouting.swift
//  carries a parsed link out.
//
//    nidus://snooze?site=youtube.com        the block page's Snooze link
//    nidus://start?goal=…&minutes=25&categories=social,video&mode=block&strict=1
//    nidus://end                            refused during a strict session
//    nidus://toggle                         what the keyboard shortcut does
//    nidus://popover                        opens the popover
//
//  Any web page can open a nidus:// link (the browser asks first), so a link
//  can start a session, but nothing in this file lets one get around strict
//  mode.
//

import Foundation

enum NidusLink: Equatable, Sendable {
    case snooze(site: String)
    case start(Start)
    case end
    case toggle
    case popover

    /// The parameters of `nidus://start`, each nil when the link leaves it out.
    /// An empty value (`minutes=`) counts as left out, so a link a Shortcut
    /// fills in with a blank variable still starts a session.
    struct Start: Equatable, Sendable {
        var goal: String?
        /// 0 means open-ended.
        var minutes: Int?
        /// What the link wrote, FocusCategory ids or names; matched later,
        /// against the categories the user has now.
        var categories: [String]?
        var mode: SessionPlan.Mode?
        var strict: Bool?
        /// A saved setup, by name or id: its choices come first, and the
        /// link's own parameters win over them.
        var preset: String?
    }

    /// Why a link was ignored. Never holds the link's values: a goal is the
    /// user's own words, and these are logged.
    enum Rejection: Error, Equatable, Sendable, CustomStringConvertible {
        case notNidus
        case unknownAction
        /// The named parameter's value is missing or not usable.
        case invalid(parameter: String)

        var description: String {
            switch self {
            case .notNidus: "not a nidus:// link"
            case .unknownAction: "unknown action"
            case .invalid(let parameter): "invalid \(parameter)"
            }
        }
    }

    static let minutesRange = 0...1440
    /// A goal is a few words; a link has no business carrying a page of text.
    static let goalLimit = 200

    init?(url: URL) {
        guard case .success(let link) = Self.parse(url) else { return nil }
        self = link
    }

    static func parse(_ url: URL) -> Result<NidusLink, Rejection> {
        guard url.scheme?.lowercased() == "nidus" else { return .failure(.notNidus) }
        let query = Query(url)
        do {
            switch url.host(percentEncoded: false)?.lowercased() {
            case "snooze": return .success(.snooze(site: try parseSite(query)))
            case "start": return .success(.start(try parseStart(query)))
            case "end": return .success(.end)
            case "toggle": return .success(.toggle)
            case "popover": return .success(.popover)
            default: return .failure(.unknownAction)
            }
        } catch {
            return .failure(error)
        }
    }

    // MARK: Parameters

    private static func parseSite(_ query: Query) throws(Rejection) -> String {
        // The same rule the block page's link always had: a site the
        // session could be blocking, as a bare domain.
        guard let site = try query.value("site"), let domain = FocusCategory.domain(from: site) else {
            throw .invalid(parameter: "site")
        }
        return domain
    }

    private static func parseStart(_ query: Query) throws(Rejection) -> Start {
        var start = Start()
        if let goal = try query.value("goal") { start.goal = cleanedGoal(goal) }

        if let text = try query.nonEmptyValue("minutes") {
            // Digits only: not "+5", "-5", "2.5" or " 25", which Int() or a
            // sloppy reading would let through.
            guard text.allSatisfy(\.isASCIIDigit), let minutes = Int(text), minutesRange.contains(minutes) else {
                throw .invalid(parameter: "minutes")
            }
            start.minutes = minutes
        }

        if let text = try query.nonEmptyValue("categories") {
            let names = text.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            start.categories = names.isEmpty ? nil : names
        }

        if let text = try query.nonEmptyValue("mode") {
            guard let mode = SessionPlan.Mode(rawValue: text.lowercased()) else {
                throw .invalid(parameter: "mode")
            }
            start.mode = mode
        }

        if let text = try query.nonEmptyValue("preset") {
            let name = cleanedGoal(text)
            guard !name.isEmpty else { throw .invalid(parameter: "preset") }
            start.preset = name
        }

        if let text = try query.nonEmptyValue("strict") {
            switch text.lowercased() {
            case "1", "true", "yes": start.strict = true
            case "0", "false", "no": start.strict = false
            default: throw .invalid(parameter: "strict")
            }
        }
        return start
    }

    /// One line, trimmed, and short: control characters (a newline would
    /// break the cards that show the goal) become spaces.
    static func cleanedGoal(_ text: String) -> String {
        let breaks: Set<Unicode.GeneralCategory> = [.control, .lineSeparator, .paragraphSeparator]
        let flat = String(text.unicodeScalars.map { breaks.contains($0.properties.generalCategory) ? " " : Character($0) })
        return String(flat.trimmingCharacters(in: .whitespacesAndNewlines).prefix(goalLimit))
    }

    // MARK: Query

    /// A link's query, read the way a browser's URLSearchParams reads it, since
    /// that is what a page building a link uses: `+` is a space, names ignore
    /// case, and the first of a repeated name wins. (A literal plus is
    /// `%2B`.) Values are decoded only when asked for, so a bad escape in a
    /// parameter nobody reads does not sink the link.
    private struct Query {
        private var raw: [String: String] = [:]

        init(_ url: URL) {
            let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
            for pair in encoded.split(separator: "&", omittingEmptySubsequences: true) {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = Self.decode(String(parts[0])) ?? String(parts[0])
                let key = name.lowercased()
                if raw[key] == nil { raw[key] = parts.count > 1 ? String(parts[1]) : "" }
            }
        }

        private static func decode(_ text: String) -> String? {
            text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        }

        /// The decoded value, nil when the name is absent; throws when the
        /// value is not valid percent-encoded UTF-8.
        func value(_ name: String) throws(Rejection) -> String? {
            guard let encoded = raw[name] else { return nil }
            guard let decoded = Self.decode(encoded) else { throw .invalid(parameter: name) }
            return decoded
        }

        /// As `value`, with an empty value read as absent.
        func nonEmptyValue(_ name: String) throws(Rejection) -> String? {
            guard let text = try value(name)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

// MARK: - Starting

extension NidusLink.Start {
    struct Resolved: Equatable, Sendable {
        var request: SessionRequest
        /// Category names the link asked for that matched nothing.
        var unmatched: [String]
    }

    /// The link's categories named something the user does not have.
    struct NoMatchingCategory: Error, Equatable, Sendable {
        var asked: [String]
    }

    /// The session this link asks for, with its category names matched
    /// (ids or names, any case) against `available`. Names that match nothing
    /// are dropped and reported; if none match, there is nothing to start: a
    /// link that said "social" should not quietly block the default pair.
    ///
    /// The goal is passed through, or "" when there is none, so a half-typed
    /// goal in the popover is never taken. Strict only ever turns on: a link
    /// that says `strict=0` leaves it to Settings, because strict mode is a
    /// promise the user made and a web page should not be able to break it.
    func resolve(against available: [FocusCategory]) -> Result<Resolved, NoMatchingCategory> {
        var ids: [String]?
        var unmatched: [String] = []
        if let names = categories {
            var matched: [String] = []
            for name in names {
                let wanted = name.lowercased()
                if let category = available.first(where: { $0.id.lowercased() == wanted })
                    ?? available.first(where: { $0.name.lowercased() == wanted }) {
                    if !matched.contains(category.id) { matched.append(category.id) }
                } else {
                    unmatched.append(name)
                }
            }
            guard !matched.isEmpty else { return .failure(NoMatchingCategory(asked: names)) }
            ids = matched
        }
        let request = SessionRequest(goal: goal ?? "", minutes: minutes, categoryIDs: ids,
                                     mode: mode, strict: strict == true ? true : nil)
        return .success(Resolved(request: request, unmatched: unmatched))
    }
}
