//
//  ActivityDrift.swift
//  Nidus
//
//  Where attention slid: a few minutes on something, then a few minutes on a
//  distraction straight after. Distracting means what it means in the hour
//  grid, a category other than Work. Read from one day's stretches, so a
//  chain never reaches across two files.
//

import Foundation

struct ActivityDriftChain: Equatable, Sendable, Identifiable {
    /// The app or site that took the most of each side, never a title.
    let origin: String
    let target: String
    /// Distracting seconds by group, kept so a range's top group is the true one.
    var groups: [String: TimeInterval]
    /// Whether Work took the most of the time before it, on any day.
    var fromWork: Bool
    var count = 1
    /// The distracting time, without what interrupted it.
    var seconds: TimeInterval

    var id: String { origin + "\u{1}" + target }

    /// The group that took the most of the distracting time.
    var category: String { ActivityDrift.top(groups) ?? ActivityCategorizer.uncategorizedID }

    mutating func add(_ other: ActivityDriftChain) {
        groups.merge(other.groups, uniquingKeysWith: +)
        fromWork = fromWork || other.fromWork
        count += other.count
        seconds += other.seconds
    }

    var times: String { count == 1 ? "once" : "\(count) times" }
}

enum ActivityDrift {
    /// Least time on either side of a chain.
    static let shortest: TimeInterval = 3 * 60
    /// Most time between the one side and the other.
    static let reach: TimeInterval = 120
    /// A gap this short doesn't end a run.
    static let join: TimeInterval = 60
    /// Non-distracting time shorter than this, inside a distraction, doesn't
    /// end it. Nothing is absorbed the other way: a blip splits an origin.
    static let interruption: TimeInterval = 30
    static let shown = 5

    private struct Run {
        let distracting: Bool
        let continuity: Int
        let start: Date
        var end: Date
        var seconds: TimeInterval = 0
        var labels: [String: TimeInterval] = [:]
        var groups: [String: TimeInterval] = [:]

        init(_ stretch: FocusActivitySegment, group: String?, distracting: Bool) {
            self.distracting = distracting
            continuity = stretch.continuity
            start = stretch.start
            end = stretch.end
            add(stretch, group: group)
        }

        mutating func add(_ stretch: FocusActivitySegment, group: String?) {
            end = max(end, stretch.end)
            seconds += stretch.seconds
            labels[stretch.site ?? stretch.appName, default: 0] += stretch.seconds
            groups[group ?? ActivityCategorizer.uncategorizedID, default: 0] += stretch.seconds
        }

        /// Absorbing an interruption leaves its time out of this run.
        mutating func add(_ run: Run) {
            end = max(end, run.end)
            seconds += run.seconds
            labels.merge(run.labels, uniquingKeysWith: +)
            groups.merge(run.groups, uniquingKeysWith: +)
        }

        func follows(_ run: Run, within gap: TimeInterval) -> Bool {
            continuity == run.continuity && start.timeIntervalSince(run.end) <= gap
        }
    }

    fileprivate static func top(_ values: [String: TimeInterval]) -> String? {
        values.min { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }?.key
    }

    /// One day's chains, in time order. A day whose start was dropped can't
    /// say what came before what, so the caller leaves it out.
    static func chains(in stretches: [FocusActivitySegment], categorizer: ActivityCategorizer) -> [ActivityDriftChain] {
        var chains: [ActivityDriftChain] = []
        let found = runs(in: stretches, categorizer: categorizer)
        for (origin, run) in zip(found, found.dropFirst())
        where run.distracting && !origin.distracting && origin.seconds >= shortest && run.seconds >= shortest
            && run.follows(origin, within: reach) {
            guard let from = top(origin.labels), let to = top(run.labels) else { continue }
            chains.append(ActivityDriftChain(origin: from, target: to, groups: run.groups,
                                             fromWork: top(origin.groups) == ActivityCategorizer.workID, seconds: run.seconds))
        }
        return chains
    }

    private static func runs(in stretches: [FocusActivitySegment], categorizer: ActivityCategorizer) -> [Run] {
        var groups: [String: String?] = [:]
        var runs: [Run] = []
        for stretch in stretches.filter({ $0.end > $0.start }).sorted(by: { $0.start < $1.start }) {
            let key = stretch.appID + "\u{1}" + (stretch.url ?? stretch.site ?? "")
            let group: String?
            if let known = groups[key] {
                group = known
            } else {
                group = categorizer.category(appID: stretch.appID, site: stretch.site, url: stretch.url)
                groups[key] = .some(group)
            }
            let distracting = group != nil && group != ActivityCategorizer.workID
            let next = Run(stretch, group: group, distracting: distracting)
            if let last = runs.last, last.distracting == distracting, next.follows(last, within: join) {
                runs[runs.count - 1].add(stretch, group: group)
            } else {
                runs.append(next)
            }
        }
        var joined: [Run] = []
        for run in runs {
            if run.distracting, joined.count >= 2 {
                let before = joined[joined.count - 2], middle = joined[joined.count - 1]
                if before.distracting, !middle.distracting, middle.seconds < interruption,
                   middle.follows(before, within: join), run.follows(middle, within: join) {
                    joined.removeLast()
                    joined[joined.count - 1].add(run)
                    continue
                }
            }
            joined.append(run)
        }
        return joined
    }

    /// The most often, then the longest. Coming out of Work only breaks a tie:
    /// a Work group can be empty, and one Work chain shouldn't hide ten others.
    static func top(_ chains: some Sequence<ActivityDriftChain>, limit: Int = shown) -> [ActivityDriftChain] {
        Array(chains.sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            if a.seconds != b.seconds { return a.seconds > b.seconds }
            if a.fromWork != b.fromWork { return a.fromWork }
            return a.id < b.id
        }.prefix(limit))
    }
}
