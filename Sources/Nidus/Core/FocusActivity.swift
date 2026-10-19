//
//  FocusActivity.swift
//  Nidus
//
//  A deliberately small activity record. A URL, page contents, document
//  contents, and input events never enter this model or the history file.
//

import Foundation

struct FocusActivity: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var appID: String
    var appName: String
    /// A recognized service label, such as Google Docs; never a hostname.
    var site: String?
    /// The optional selected page or document name.
    var title: String?
    var seconds: TimeInterval

    init(id: String = UUID().uuidString, appID: String, appName: String,
         site: String? = nil, title: String? = nil, seconds: TimeInterval) {
        self.id = id
        self.appID = appID
        self.appName = appName
        self.site = site
        self.title = title
        self.seconds = seconds
    }
}

/// A bounded, ordered observation of the frontmost work context. Its dates
/// describe time actually sampled; a gap never stands for continued work.
struct FocusActivitySegment: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var start: Date
    var end: Date
    var appID: String
    var appName: String
    var site: String?
    var title: String?
    /// Changes at a pause or relaunch, even when two dates happen to touch.
    var continuity: Int

    var seconds: TimeInterval { max(0, end.timeIntervalSince(start)) }

    init(id: String = UUID().uuidString, start: Date, end: Date, appID: String,
         appName: String, site: String? = nil, title: String? = nil, continuity: Int = 0) {
        self.id = id
        self.start = start
        self.end = end
        self.appID = appID
        self.appName = appName
        self.site = site
        self.title = title
        self.continuity = continuity
    }
}

enum ActivityTimeline {
    static let limit = 512
    /// Sampling intervals must touch to prove an uninterrupted stretch.
    static let tolerance: TimeInterval = 0

    /// Only labels emitted by the local probe enter the persisted model.
    /// Hostnames, URLs, paths, and arbitrary page text are never site labels.
    static func safeSite(_ site: String?) -> String? {
        guard let site else { return nil }
        let labels: Set<String> = ["Google Docs", "Claude", "Microsoft Word", "Claude Science", "Capsid"]
        return labels.contains(site) ? site : nil
    }

    static func sameContext(_ a: FocusActivitySegment, _ b: FocusActivitySegment) -> Bool {
        a.appID == b.appID && a.site == b.site && a.title == b.title
    }

    static func touches(_ a: FocusActivitySegment, _ b: FocusActivitySegment) -> Bool {
        a.continuity == b.continuity && b.start.timeIntervalSince(a.end) <= tolerance && b.start >= a.end
    }

    /// A short app-activation edge can leave a partial sampled interval. A
    /// skipped tick explicitly changes continuity, so it cannot bridge here.
    static func adjacentObservation(_ a: FocusActivitySegment, _ b: FocusActivitySegment) -> Bool {
        let gap = b.start.timeIntervalSince(a.end)
        return a.continuity == b.continuity && gap >= 0 && gap <= 1.25
    }

    /// A title becoming known after a probe is not evidence of a switch.
    static func isSwitch(_ a: FocusActivitySegment, _ b: FocusActivitySegment) -> Bool {
        a.appID != b.appID ||
            (a.site != nil && b.site != nil && a.site != b.site) ||
            (a.site == b.site && a.title != nil && b.title != nil && a.title != b.title)
    }

    static func switchCount(_ segments: [FocusActivitySegment]) -> Int {
        zip(segments, segments.dropFirst()).reduce(0) { count, pair in
            count + (adjacentObservation(pair.0, pair.1) && isSwitch(pair.0, pair.1) ? 1 : 0)
        }
    }

    static func longestStretch(_ segments: [FocusActivitySegment]) -> TimeInterval {
        var longest: TimeInterval = 0
        var run: TimeInterval = 0
        var previous: FocusActivitySegment?
        for segment in segments where segment.end > segment.start {
            if let previous, touches(previous, segment), sameContext(previous, segment) {
                run += segment.seconds
            } else {
                run = segment.seconds
            }
            longest = max(longest, run)
            previous = segment
        }
        return longest
    }
}


/// Taking the names out of recorded activity, for a running session or a
/// finished one alike. Rows that differed only by name become one; on the
/// timeline, a switch between two documents stays a switch (its continuity
/// is bumped) though neither is named any more.
enum ActivityRedaction {
    static func withoutTitles(_ activity: [FocusActivity]) -> [FocusActivity] {
        var collapsed: [FocusActivity] = []
        for var row in activity {
            row.title = nil
            if let index = collapsed.firstIndex(where: { $0.appID == row.appID && $0.site == row.site }) {
                collapsed[index].seconds += row.seconds
            } else {
                collapsed.append(row)
            }
        }
        return collapsed
    }

    static func withoutTitles(_ segments: [FocusActivitySegment]) -> [FocusActivitySegment] {
        var redacted: [FocusActivitySegment] = []
        var offset = 0
        var previous: FocusActivitySegment?
        for var segment in segments {
            if let previous, previous.appID == segment.appID,
               previous.site == segment.site, previous.title != segment.title {
                // After title removal these contexts look identical;
                // retain the observed boundary without retaining names.
                offset += 1
            }
            previous = segment
            segment.continuity += offset
            segment.title = nil
            redacted.append(segment)
        }
        return redacted
    }

    static func hasTitles(_ activity: [FocusActivity]?, _ segments: [FocusActivitySegment]?) -> Bool {
        (activity ?? []).contains { $0.title != nil } || (segments ?? []).contains { $0.title != nil }
    }
}
