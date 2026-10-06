//
//  FocusCommands.swift
//  Nidus
//
//  The JSON command, for scripts and assistants: one request in, one result
//  out, through the "Run Nidus Command" Shortcuts action (and a one-step
//  shortcut around it that `shortcuts run` can call). It is a thin
//  dispatcher over FocusOutside.swift's commands, so it keeps the same rules
//  as the popover, links and the other actions; docs/automation.md has the
//  contract. Goals pass through and are never logged.
//

import AppKit

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Finding a setup

/// A setup asked for by id (stable across renames) or by exact name.
enum SetupLookup: Equatable {
    case found(FocusSetup)
    case notFound
    /// Two or more setups share the name: only the id says which.
    case ambiguous
}

extension FocusSetup {
    static func find(_ key: String, in setups: [FocusSetup]) -> SetupLookup {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if let byID = setups.first(where: { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame }) {
            return .found(byID)
        }
        let named = setups.filter { $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(key) == .orderedSame }
        switch named.count {
        case 0: return .notFound
        case 1: return .found(named[0])
        default: return .ambiguous
        }
    }

    /// `nidus://start?preset=<id>`: starts this setup from a launcher. By id,
    /// so renaming the setup doesn't break it; the goal stays out of it.
    var launchLink: URL {
        var components = URLComponents()
        components.scheme = "nidus"
        components.host = "start"
        components.queryItems = [URLQueryItem(name: "preset", value: id.uuidString)]
        return components.url!
    }
}

extension NidusModel {
    /// Puts a setup's `nidus://start?preset=<id>` link on the clipboard.
    func copyLaunchLink(for setup: FocusSetup) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(setup.launchLink.absoluteString, forType: .string)
        host?.feedback.play(.tick)
    }
}

extension FocusFormat {
    /// "18 minutes", "1 hour 30 minutes": for sentences said aloud.
    static func minutes(_ minutes: Int) -> String {
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        let hours = minutes / 60, rest = minutes % 60
        switch (hours, rest) {
        case (0, _): return unit(rest, "minute")
        case (_, 0): return unit(hours, "hour")
        default: return "\(unit(hours, "hour")) \(unit(rest, "minute"))"
        }
    }

    /// "Started Writing for 45 minutes.", from the status just after.
    static func started(_ setup: FocusSetup?, status: FocusStatus) -> String {
        let what = setup?.displayName ?? "focus"
        if status.isOpenEnded { return "Started \(what), open-ended." }
        guard let left = status.minutesLeft else { return "Started \(what)." }
        return "Started \(what) for \(minutes(left))."
    }
}

// MARK: - The contract

/// A request, version 1. Every field but `action` is optional; what a start
/// leaves out comes from the setup it names, then the popover's choices.
struct FocusCommandRequest: Decodable, Equatable {
    var version: Int?
    /// `status`, `setups`, `start`, `addTime` or `end`.
    var action: String
    /// Any string the caller makes up for a start, add or end: sent again
    /// after a timeout, the same id gets the first answer back instead of
    /// doing it twice.
    var id: String?
    var goal: String?
    /// For a start, 0 to 1440, 0 being open-ended; for addTime, 1 to 1440.
    var minutes: Int?
    /// A setup's id or exact name.
    var setup: String?
    /// Category ids or names.
    var categories: [String]?
    /// `block` or `allow`.
    var mode: String?
    /// Only `true` does anything: strict turns on, never off.
    var strict: Bool?
}

struct FocusCommandResponse: Encodable, Equatable {
    struct Status: Encodable, Equatable {
        var state: String
        var isOn: Bool
        var isBlocking: Bool
        var isOpenEnded: Bool
        var isStrict: Bool
        /// Of the session; nil on a break (see breakMinutesLeft).
        var minutesLeft: Int?
        var secondsLeft: Int?
        var breakMinutesLeft: Int?
        var endsAt: String?
        var observedAt: String
        var browsersNeedingAccess: [String]
        var sentence: String
    }

    struct Setup: Encodable, Equatable {
        var id: String
        var name: String
        var summary: String
        var minutes: Int
        var strict: Bool
    }

    var version = 1
    var ok: Bool
    var action: String
    var outcome: String
    var message: String
    var status: Status?
    var addedMinutes: Int?
    var setups: [Setup]?
    /// This id was answered before; this is that answer, and nothing was
    /// done again.
    var duplicate: Bool?
}

/// Recent successful answers to requests that changed something, by id, so
/// a retry after a timeout can't start twice or add time twice. Only what
/// worked is kept: a refusal changed nothing, so retrying it simply runs
/// again. In memory and for ten minutes: a relaunch forgets them, and "check
/// status first" covers that.
@MainActor
final class FocusCommandLedger {
    private struct Entry {
        let key: String
        let request: FocusCommandRequest
        let response: FocusCommandResponse
        let at: Date
    }

    enum Recall: Equatable {
        case new
        /// The same request again: here is what it got.
        case answered(FocusCommandResponse)
        /// The id was used for a different request.
        case reused
    }

    private var entries: [Entry] = []
    static let capacity = 32
    static let lifetime: TimeInterval = 10 * 60

    func recall(_ request: FocusCommandRequest, key: String, now: Date = Date()) -> Recall {
        entries.removeAll { now.timeIntervalSince($0.at) > Self.lifetime }
        guard let entry = entries.last(where: { $0.key == key }) else { return .new }
        return entry.request == request ? .answered(entry.response) : .reused
    }

    func remember(_ response: FocusCommandResponse, to request: FocusCommandRequest, key: String, now: Date = Date()) {
        guard response.ok else { return }
        entries.append(Entry(key: key, request: request, response: response, at: now))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }
}

// MARK: - Running one

@MainActor
enum FocusCommands {
    static let version = 1

    /// Reads a request, runs it on `target` (nil: Nidus isn't up), and
    /// writes the answer. Always JSON back, even for a request it can't read.
    static func respond(to text: String, target: FocusCommandTarget?, ledger: FocusCommandLedger,
                        now: Date = Date()) -> String {
        let response: FocusCommandResponse
        if let data = text.data(using: .utf8),
           let request = try? JSONDecoder().decode(FocusCommandRequest.self, from: data) {
            response = run(request, target: target, ledger: ledger, now: now)
        } else {
            response = failure("", "invalidRequest", "That isn't a Nidus request. Send JSON with an action.", status: target?.commandStatus)
        }
        return encode(response)
    }

    static func run(_ request: FocusCommandRequest, target: FocusCommandTarget?, ledger: FocusCommandLedger,
                    now: Date = Date()) -> FocusCommandResponse {
        let action = request.action
        guard (request.version ?? version) == version else {
            return failure(action, "unsupportedVersion", "This Nidus understands version \(version) requests.", status: target?.commandStatus)
        }
        guard let target else {
            return failure(action, "notReady", "Nidus isn't running, or is still starting. Open it and try again.", status: nil)
        }
        let changes = ["start", "addTime", "end"].contains(action)
        // A blank id is no id.
        let id = request.id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = id.flatMap { $0.isEmpty ? nil : "\(action)\u{1F}\($0)" }
        if changes, let key {
            switch ledger.recall(request, key: key, now: now) {
            case .new: break
            case .answered(var earlier):
                earlier.duplicate = true
                earlier.status = status(target.commandStatus)
                return earlier
            case .reused:
                return failure(action, "idReused", "That id was already used for a different request, so nothing was done. Use a new id.",
                               status: target.commandStatus)
            }
        }
        let response: FocusCommandResponse
        switch action {
        case "status":
            let now = target.commandStatus
            response = success(action, "ok", now.sentence, status: now)
        case "setups":
            var answer = success(action, "ok", target.setups.isEmpty ? "No setups yet." : "\(target.setups.count) setups.",
                                 status: target.commandStatus)
            answer.setups = target.setups.map {
                .init(id: $0.id.uuidString, name: $0.displayName, summary: $0.planSummary(categories: target.categories),
                      minutes: $0.minutes, strict: $0.strict)
            }
            response = answer
        case "start": response = start(request, on: target)
        case "addTime": response = addTime(request, on: target)
        case "end": response = end(on: target)
        default:
            response = failure(action, "unknownAction", "Nidus can do status, setups, start, addTime and end.", status: target.commandStatus)
        }
        if changes, let key { ledger.remember(response, to: request, key: key, now: now) }
        return response
    }

    private static func start(_ request: FocusCommandRequest, on target: FocusCommandTarget) -> FocusCommandResponse {
        if let minutes = request.minutes, !NidusLink.minutesRange.contains(minutes) {
            return failure("start", "invalidMinutes", "Minutes must be from 0 to 1440; 0 is open-ended.", status: target.commandStatus)
        }
        var mode: SessionPlan.Mode?
        if let text = request.mode {
            guard let parsed = SessionPlan.Mode(rawValue: text.lowercased()) else {
                return failure("start", "invalidMode", "Mode is block or allow.", status: target.commandStatus)
            }
            mode = parsed
        }
        // Blank is the same as left out: an empty goal doesn't wipe a setup's,
        // an empty setup name isn't a setup, and no categories means the usual.
        let goal = request.goal.map(NidusLink.cleanedGoal).flatMap { $0.isEmpty ? nil : $0 }
        let setup = request.setup?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let categories = request.categories?.isEmpty == true ? nil : request.categories
        let ask = NidusLink.Start(goal: goal, minutes: request.minutes, categories: categories, mode: mode,
                                  strict: request.strict == true ? true : nil, preset: setup)
        switch target.outsideRequest(ask) {
        case .failure(.setupNotFound):
            return failure("start", "setupNotFound", "There's no setup by that name or id. Ask for setups to see them.", status: target.commandStatus)
        case .failure(.setupAmbiguous):
            return failure("start", "setupAmbiguous", "More than one setup has that name. Use its id.", status: target.commandStatus)
        case .failure(.noMatchingCategory):
            return failure("start", "noMatchingCategory", "None of those categories is in Nidus.", status: target.commandStatus)
        case .success(let resolved):
            var asked = resolved.request
            // Started from afar: macOS's permission prompts would wait on a
            // screen nobody may be at. Status names browsers left unblocked.
            asked.asksBrowserAccess = false
            switch target.startFromOutside(asked) {
            case .started:
                let now = target.commandStatus
                return success("start", "started", FocusFormat.started(resolved.setup, status: now), status: now)
            case .busy:
                let now = target.commandStatus
                return failure("start", "busy", "A session or break is already on, so nothing new started. \(now.sentence)", status: now)
            case .nothingToBlock:
                return failure("start", "nothingToBlock", "There's nothing to block. Add apps or websites to a category in Nidus.", status: target.commandStatus)
            case .notReady:
                return failure("start", "notReady", "Nidus is still starting. Try again in a moment.", status: target.commandStatus)
            }
        }
    }

    private static func addTime(_ request: FocusCommandRequest, on target: FocusCommandTarget) -> FocusCommandResponse {
        let outcome = target.addTimeFromOutside(minutes: request.minutes ?? 0)
        let now = target.commandStatus
        let left = now.minutesLeft.map { " You have \(FocusFormat.minutes($0)) left." } ?? ""
        switch outcome {
        case .added(let minutes):
            var answer = success("addTime", "added", "Added \(FocusFormat.minutes(minutes)).\(left)", status: now)
            answer.addedMinutes = minutes
            return answer
        case .atMaximum:
            var answer = failure("addTime", "atMaximum", "Nothing added: a session can't run more than 24 hours.\(left)", status: now)
            answer.addedMinutes = 0
            return answer
        case .openEnded: return failure("addTime", "openEnded", "This session is open-ended, so there's no end to move.", status: now)
        case .onBreak: return failure("addTime", "onBreak", "You're on a break, so there's no session to add to.", status: now)
        case .nothingRunning: return failure("addTime", "nothingRunning", "Focus isn't on, so there's nothing to add to.", status: now)
        case .invalidMinutes: return failure("addTime", "invalidMinutes", "Minutes must be from 1 to 1440.", status: now)
        }
    }

    private static func end(on target: FocusCommandTarget) -> FocusCommandResponse {
        let outcome = target.endFromOutside()
        let now = target.commandStatus
        switch outcome {
        case .endsSession: return success("end", "ended", "Focus ended.", status: now)
        case .endsBreak: return success("end", "endedBreak", "Break ended.", status: now)
        case .nothingRunning: return failure("end", "nothingRunning", "Focus isn't on.", status: now)
        case .refusesStrict: return failure("end", "refusedStrict", "This is a strict session. End it from the menu bar.", status: now)
        }
    }

    // MARK: Writing it

    private static func success(_ action: String, _ outcome: String, _ message: String, status now: FocusStatus?) -> FocusCommandResponse {
        FocusCommandResponse(ok: true, action: action, outcome: outcome, message: message, status: now.map(status))
    }

    private static func failure(_ action: String, _ outcome: String, _ message: String, status now: FocusStatus?) -> FocusCommandResponse {
        FocusCommandResponse(ok: false, action: action, outcome: outcome, message: message, status: now.map(status))
    }

    static func status(_ status: FocusStatus) -> FocusCommandResponse.Status {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = .current
        return .init(state: status.state.rawValue, isOn: status.isOn, isBlocking: status.isBlocking,
                     isOpenEnded: status.isOpenEnded, isStrict: status.isStrict,
                     minutesLeft: status.sessionMinutesLeft,
                     secondsLeft: status.state == .onBreak ? nil : status.secondsLeft,
                     breakMinutesLeft: status.state == .onBreak ? status.minutesLeft : nil,
                     endsAt: status.endsAt.map(iso.string(from:)), observedAt: iso.string(from: status.observedAt),
                     browsersNeedingAccess: status.browsersNeedingAccess, sentence: status.sentence)
    }

    static func encode(_ response: FocusCommandResponse) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(response)).flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"version":1,"ok":false,"action":"","outcome":"internalError","message":"Nidus couldn't write its answer."}"#
    }
}
