//
//  PlaqueFocusSnapshot.swift
//  Nidus
//
//  What Nidus tells Plaque about focus, when the person turns it on:
//  `plaque-focus.json`, version 1 (docs/design-0.4.md, "Plaque focus
//  display"). Separate from `focus.json`, which other Solanum apps read and
//  which stays as it was. Pure: the state goes in, the file's value comes
//  out, so the tests pin the clock and compare against the golden file.
//
//  No DroppyKit import: this file also compiles into the tests.
//

import CryptoKit
import Foundation

struct PlaqueFocusSnapshot: Codable, Equatable, Sendable {
    static let schemaName = "local.sam.nidus.plaque-focus"
    static let currentVersion = 1

    enum State: String, Codable, Sendable {
        case idle, focusing, paused, `break`, finished, offline
    }

    struct Session: Codable, Equatable, Sendable {
        var id: String
        var startedAt: Date
    }

    struct Next: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case `break`, block, finish }
        var kind: Kind
        var startsAt: Date?
        var minutes: Int?
    }

    struct Sequence: Codable, Equatable, Sendable {
        /// Words the person typed: only with text sharing.
        var name: String?
        /// 1-based, counting work blocks only.
        var step: Int
        var count: Int
    }

    /// Only when the person chose to share it.
    struct Text: Codable, Equatable, Sendable {
        var goal: String?
        var project: String?
        var nextStep: String?
    }

    var schema = Self.schemaName
    var version = Self.currentVersion
    var revision: Int
    var updatedAt: Date
    var expiresAt: Date
    var state: State
    var session: Session?
    var endsAt: Date?
    var openEnded: Bool
    var pausedRemainingSeconds: Int?
    var strict: Bool
    var next: Next?
    var sequence: Sequence?
    var text: Text?

    // MARK: Limits

    static let goalLimit = 120
    static let projectLimit = 60
    static let nextStepLimit = 160
    static let sequenceNameLimit = 60
    /// The whole file stays under this.
    static let byteLimit = 4096
    /// How long a snapshot is good for once written while something is on.
    static let liveLifetime: TimeInterval = 15 * 60
    /// How long an idle or offline one is good for.
    static let restingLifetime: TimeInterval = 24 * 60 * 60
    /// How often it is written again while nothing changes but time.
    static let heartbeat: TimeInterval = 5 * 60
    /// How long "finished" stays before it turns to idle.
    static let finishedLinger: TimeInterval = 15 * 60

    // MARK: Making one

    /// Nidus's state, as the snapshot needs it.
    struct Input: Equatable, Sendable {
        enum Phase: Equatable, Sendable {
            case idle
            /// `endsAt` nil for an open-ended session.
            case focusing(endsAt: Date?)
            case paused(remaining: TimeInterval)
            case onBreak(endsAt: Date)
            case finished
            case offline
        }

        var phase: Phase
        var sessionID: String?
        var startedAt: Date?
        var strict = false
        var next: Next?
        var sequence: Sequence?
        var goal: String?
        var project: String?
        var nextStep: String?

        init(phase: Phase, sessionID: String? = nil, startedAt: Date? = nil, strict: Bool = false,
             next: Next? = nil, sequence: Sequence? = nil,
             goal: String? = nil, project: String? = nil, nextStep: String? = nil) {
            self.phase = phase
            self.sessionID = sessionID
            self.startedAt = startedAt
            self.strict = strict
            self.next = next
            self.sequence = sequence
            self.goal = goal
            self.project = project
            self.nextStep = nextStep
        }
    }

    /// The snapshot for `input` at `now`. Text goes in only with `sharesText`,
    /// trimmed and cut to its limit; blank text is left out.
    static func make(_ input: Input, revision: Int, now: Date, sharesText: Bool) -> PlaqueFocusSnapshot {
        let now = wholeSecond(now)
        let state: State
        var endsAt: Date?
        var paused: Int?
        var openEnded = false
        switch input.phase {
        case .idle: state = .idle
        case .focusing(let end):
            state = .focusing
            endsAt = end.map(wholeSecond)
            openEnded = end == nil
        case .paused(let remaining):
            state = .paused
            paused = max(0, Int(remaining.rounded(.up)))
        case .onBreak(let end):
            state = .break
            endsAt = wholeSecond(end)
        case .finished: state = .finished
        case .offline: state = .offline
        }
        let resting = state == .idle || state == .offline
        var session: Session?
        if !resting, let id = input.sessionID, let startedAt = input.startedAt {
            session = Session(id: id, startedAt: wholeSecond(startedAt))
        }
        var text: Text?
        if sharesText, !resting {
            let shared = Text(goal: bounded(input.goal, goalLimit), project: bounded(input.project, projectLimit),
                              nextStep: state == .finished ? bounded(input.nextStep, nextStepLimit) : nil)
            if shared.goal != nil || shared.project != nil || shared.nextStep != nil { text = shared }
        }
        var sequence = resting ? nil : input.sequence
        let sequenceName = sharesText ? bounded(sequence?.name, sequenceNameLimit) : nil
        sequence?.name = sequenceName
        var next = resting || state == .finished ? nil : input.next
        if let startsAt = next?.startsAt { next?.startsAt = wholeSecond(startsAt) }
        return PlaqueFocusSnapshot(
            revision: revision, updatedAt: now,
            expiresAt: now.addingTimeInterval(resting ? restingLifetime : liveLifetime),
            state: state, session: session, endsAt: endsAt, openEnded: openEnded,
            pausedRemainingSeconds: paused, strict: resting ? false : input.strict,
            next: next, sequence: sequence, text: text)
    }

    /// Whether `other` says something different, leaving aside when each was
    /// written: a change is written at once, the same state only on the heartbeat.
    func sameContent(as other: PlaqueFocusSnapshot) -> Bool {
        var a = self, b = other
        a.revision = 0; b.revision = 0
        a.updatedAt = .distantPast; b.updatedAt = .distantPast
        a.expiresAt = .distantPast; b.expiresAt = .distantPast
        return a == b
    }

    /// A stable id for the session that started at `startedAt`: the same
    /// across a relaunch, different for every session, and saying nothing
    /// about what the session is.
    static func sessionID(startedAt: Date) -> String {
        let millis = Int64((startedAt.timeIntervalSinceReferenceDate * 1000).rounded())
        var bytes = Array(SHA256.hash(data: Data("nidus-session-\(millis)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5-style
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }

    // MARK: The file

    /// The file's bytes: ISO 8601 dates, keys sorted, empty values left out.
    /// nil if it would pass the size limit, which bounded text makes
    /// impossible in practice.
    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), data.count <= Self.byteLimit else { return nil }
        return data
    }

    static func decoded(from data: Data) -> PlaqueFocusSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PlaqueFocusSnapshot.self, from: data)
    }

    private static func wholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    private static func bounded(_ text: String?, _ limit: Int) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }
}
