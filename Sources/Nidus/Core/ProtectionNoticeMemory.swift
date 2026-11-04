// Acknowledging a warning keeps it quiet without hiding the protection gap.
// Only actual, running gaps are offered; a new browser or permission failure
// is a different warning. Both collections have a small fixed ceiling.
import Foundation

struct ProtectionNoticeMemory: Equatable {
    static let limit = 64
    private(set) var acknowledged: [String]
    private var presented: [String] = []

    init(acknowledged: [String] = []) {
        self.acknowledged = Array(acknowledged.suffix(Self.limit))
    }

    mutating func nextWarnings(for relevant: [String]) -> [String] {
        let relevantSet = Set(relevant)
        presented.removeAll { !relevantSet.contains($0) }
        let known = Set(acknowledged + presented)
        return Array(relevant.filter { !known.contains($0) }.prefix(Self.limit))
    }

    mutating func didPresent(_ keys: [String]) {
        for key in keys where !presented.contains(key) { presented.append(key) }
        presented = Array(presented.suffix(Self.limit))
    }

    mutating func acknowledge(_ keys: [String]) {
        for key in keys {
            acknowledged.removeAll { $0 == key }
            acknowledged.append(key)
        }
        acknowledged = Array(acknowledged.suffix(Self.limit))
    }
}
