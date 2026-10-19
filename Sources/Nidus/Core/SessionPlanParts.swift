//
//  SessionPlanParts.swift
//  Nidus
//
//  What a session plan carries beyond 0.3's blocking rules: the break that
//  follows it, the exceptions inside its block list, the documents and pages
//  it opens, and its place in a sequence. These are the shapes only; what
//  each does lives with its feature (docs/design-0.4.md says which file).
//
//  Everything decodes field by field: a value one version writes wrongly
//  loses only itself, never the session or the setup around it.
//
//  Shared by the app and its tests.
//

import Foundation

// MARK: - Breaks with their own rules

/// What stays blocked during a break. Empty: an unrestricted break, as every
/// break was before 0.4. Always block mode: a break never narrows to an
/// allow list.
struct BreakRules: Codable, Equatable, Hashable, Sendable {
    /// Bundle identifiers blocked during the break.
    var apps: [String] = []
    /// Website rules, the same strings a category holds.
    var websites: [String] = []
    /// A short note to self shown while the break runs ("Stretch, water").
    var reminder: String?

    static let reminderLimit = 120

    init(apps: [String] = [], websites: [String] = [], reminder: String? = nil) {
        self.apps = apps
        self.websites = websites
        self.reminder = reminder
    }

    /// Nothing blocked: the break lets everything through.
    var isUnrestricted: Bool { apps.isEmpty && websites.isEmpty }

    /// The reminder as shown: trimmed, bounded, nil when blank.
    var displayReminder: String? {
        guard let text = reminder?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(Self.reminderLimit))
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apps = c.decodeLossy([String].self, forKey: .apps)
        websites = c.decodeLossy([String].self, forKey: .websites)
        reminder = c.decodeTolerant(String.self, forKey: .reminder)
    }

    enum CodingKeys: String, CodingKey { case apps, websites, reminder }
}

// MARK: - Website exceptions

/// A page let through although a broader rule in the block list covers it:
/// one research video on a blocked video site. Block mode only; an allow
/// list already says what is let through.
///
/// `address` is kept as typed or pasted. How it is normalized and matched
/// (hosts, ports, encoding, which query parameters identify the page) is
/// decided in one place, WebsiteException+Matching.swift.
struct WebsiteException: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        /// This page only: its host, path and identifying query, nothing below it.
        case exact
        /// This path and everything below it, on this host only.
        case subtree
    }

    var kind: Kind
    var address: String

    var id: String { kind.rawValue + " " + address }

    init(kind: Kind, address: String) {
        self.kind = kind
        self.address = address
    }
}

// MARK: - Workspaces

/// Something a session opens when it starts: a document, a folder or a web
/// page. Files are held by bookmark, so one that was moved is still found;
/// the path is kept to say which file is missing when it is not.
struct WorkspaceResource: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case document, folder, webPage }

    var id: UUID
    var kind: Kind
    /// What lists show: the file's name, or the page's address.
    var displayName: String
    /// A bookmark to the file or folder.
    var bookmark: Data?
    /// The file's path when it was chosen.
    var path: String?
    /// The page's address, http or https only.
    var url: String?

    init(id: UUID = UUID(), kind: Kind, displayName: String, bookmark: Data? = nil, path: String? = nil, url: String? = nil) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.bookmark = bookmark
        self.path = path
        self.url = url
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        displayName = c.decodeTolerant(String.self, forKey: .displayName) ?? ""
        bookmark = c.decodeTolerant(Data.self, forKey: .bookmark)
        path = c.decodeTolerant(String.self, forKey: .path)
        url = c.decodeTolerant(String.self, forKey: .url)
    }

    enum CodingKeys: String, CodingKey { case id, kind, displayName, bookmark, path, url }
}

// MARK: - Sequences

/// Where a session sits in a running sequence: copied into its history entry.
struct SequenceStepRef: Codable, Equatable, Hashable, Sendable {
    /// The run, not the saved sequence: running the same sequence twice is two runs.
    var runID: UUID
    /// 0-based, counting work blocks and breaks alike.
    var index: Int
    var count: Int
}

/// One step of a sequence, resolved when the sequence starts.
enum SequenceStep: Codable, Equatable, Sendable {
    /// A work block: a whole session plan, setup and project already applied.
    case work(SessionPlan)
    /// A break of this length, with what stays blocked during it.
    case rest(length: TimeInterval, rules: BreakRules?)

    var isWork: Bool { if case .work = self { true } else { false } }
}

/// A sequence in progress, snapshotted when it started: editing the saved
/// sequence (or a setup it uses) changes nothing about a run under way.
struct SequenceRun: Codable, Equatable, Sendable {
    var id: UUID
    /// The saved sequence it was started from; nil for one built on the spot.
    var sequenceID: UUID?
    var name: String
    var steps: [SequenceStep]
    /// The step running now.
    var index: Int
    var startedAt: Date

    init(id: UUID = UUID(), sequenceID: UUID? = nil, name: String, steps: [SequenceStep], index: Int = 0, startedAt: Date) {
        self.id = id
        self.sequenceID = sequenceID
        self.name = name
        self.steps = steps
        self.index = index
        self.startedAt = startedAt
    }

    var current: SequenceStep? { steps.indices.contains(index) ? steps[index] : nil }
    var next: SequenceStep? { steps.indices.contains(index + 1) ? steps[index + 1] : nil }
    var isLastStep: Bool { index >= steps.count - 1 }

    func ref(at index: Int) -> SequenceStepRef { SequenceStepRef(runID: id, index: index, count: steps.count) }
}
