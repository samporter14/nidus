//
//  ActivityRibbonBands.swift
//  Nidus
//
//  A day by category reads as a few blocks, not hundreds of slivers. Runs of
//  one category join across small gaps, and a short interruption goes into
//  what it interrupted. What a block holds stays in its detail, and each
//  block keeps the time actually counted inside it.
//

import Foundation

enum ActivityRibbonBands {
    /// Two runs this close together are one sitting.
    static let bridge: TimeInterval = 15 * 60
    /// Tried smallest first, so a short run joins its neighbor before that
    /// neighbor is itself judged.
    static let steps: [TimeInterval] = [60, 3 * 60, 5 * 60, 10 * 60]
    private static let namesShown = 3

    private struct Band {
        var first: ActivityRibbon.Block
        var end: Date
        var series: Int
        /// Seconds by name, across everything inside.
        var parts: [String: TimeInterval]
        var seconds: TimeInterval { parts.values.reduce(0, +) }
        var start: Date { first.start }

        init(_ block: ActivityRibbon.Block) {
            first = block
            end = block.end
            series = block.series
            parts = [block.name: block.seconds]
        }

        mutating func take(_ other: Band) {
            if other.start < start { first = other.first }
            end = max(end, other.end)
            parts.merge(other.parts, uniquingKeysWith: +)
        }
    }

    static func merged(_ blocks: [ActivityRibbon.Block], seriesName: (Int) -> String) -> [ActivityRibbon.Block] {
        var bands = coalesced(blocks.sorted { $0.start < $1.start }.map(Band.init))
        for step in steps {
            bands = coalesced(absorbing(bands, shorterThan: step))
        }
        return bands.map { band in
            let named = band.parts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            let shown = named.prefix(namesShown).map(\.key).joined(separator: ", ")
            let rest = named.count - namesShown
            return ActivityRibbon.Block(id: band.first.id, start: band.start, end: band.end, series: band.series,
                                        name: seriesName(band.series),
                                        detail: rest > 0 ? "\(shown) and \(rest) more" : shown,
                                        counted: band.seconds)
        }
    }

    private static func coalesced(_ bands: [Band]) -> [Band] {
        var result: [Band] = []
        for band in bands {
            if let last = result.last, last.series == band.series, band.start.timeIntervalSince(last.end) <= bridge {
                result[result.count - 1].take(band)
            } else {
                result.append(band)
            }
        }
        return result
    }

    /// A short band goes to the longer neighbor within reach, and the
    /// neighbor keeps its category. One with neither stands alone: an
    /// isolated moment is still what happened.
    private static func absorbing(_ bands: [Band], shorterThan limit: TimeInterval) -> [Band] {
        var result: [Band] = []
        var index = 0
        while index < bands.count {
            let band = bands[index]
            let previous = result.last.flatMap { band.start.timeIntervalSince($0.end) <= bridge ? $0 : nil }
            let next = index + 1 < bands.count && bands[index + 1].start.timeIntervalSince(band.end) <= bridge
                ? bands[index + 1] : nil
            guard band.seconds < limit, previous != nil || next != nil else {
                result.append(band)
                index += 1
                continue
            }
            if let previous, previous.seconds >= next?.seconds ?? 0 {
                result[result.count - 1].take(band)
                index += 1
            } else if var next {
                next.take(band)
                result.append(next)
                index += 2
            }
        }
        return result
    }
}
