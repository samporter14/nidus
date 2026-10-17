//
//  FocusProject.swift
//  Nidus
//
//  A project: a name that sessions, setups, sequences and resume notes can
//  point to by a stable id, so "Grant" is still the same project after it is
//  renamed "R01 renewal". Lightweight on purpose: no tasks, no due dates.
//
//  No DroppyKit import: this file also compiles into the tests.
//

import Foundation

struct FocusProject: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// Archived projects keep their history and notes but aren't offered for
    /// new sessions.
    var isArchived: Bool
    var createdAt: Date

    static let nameLimit = 60

    init(id: UUID = UUID(), name: String, isArchived: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.isArchived = isArchived
        self.createdAt = createdAt
    }

    /// The name as shown: never empty, never longer than a row can hold.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled project" : String(trimmed.prefix(Self.nameLimit))
    }

    /// Only the id and name must be there.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isArchived = c.decodeTolerant(Bool.self, forKey: .isArchived) ?? false
        createdAt = c.decodeTolerant(Date.self, forKey: .createdAt) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    enum CodingKeys: String, CodingKey { case id, name, isArchived, createdAt }
}
