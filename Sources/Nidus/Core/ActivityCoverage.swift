import Foundation

/// The union of observed intervals, built once and reused across sessions.
/// Gaps remain gaps; a surviving stretch never stands for the whole day.
struct ActivityCoverage {
    private(set) var ranges: [DateInterval] = []

    init(intervals: some Sequence<DateInterval>) {
        for range in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = ranges.last, range.start <= last.end {
                ranges[ranges.count - 1] = DateInterval(start: last.start, end: max(last.end, range.end))
            } else {
                ranges.append(range)
            }
        }
    }

    /// Whether any of this interval is covered.
    func overlaps(_ interval: DateInterval) -> Bool {
        let index = firstEnding(after: interval.start)
        return index < ranges.count && ranges[index].start < interval.end
    }

    /// Portions of these observations not covered by another source. Metadata
    /// and continuity are retained, while split pieces receive distinct IDs.
    func uncovered(_ segments: [FocusActivitySegment]) -> [FocusActivitySegment] {
        var result: [FocusActivitySegment] = []
        for segment in segments where segment.end > segment.start {
            var cursor = segment.start
            var index = firstEnding(after: segment.start)
            func append(until end: Date) {
                guard end > cursor else { return }
                var piece = segment
                piece.start = cursor
                piece.end = end
                if piece.start != segment.start || piece.end != segment.end {
                    piece.id = "\(segment.id)@uncovered:\(cursor.timeIntervalSinceReferenceDate)"
                }
                result.append(piece)
            }
            while index < ranges.count, ranges[index].start < segment.end {
                let range = ranges[index]
                append(until: min(range.start, segment.end))
                cursor = max(cursor, range.end)
                if cursor >= segment.end { break }
                index += 1
            }
            append(until: segment.end)
        }
        return result
    }

    private func firstEnding(after start: Date) -> Int {
        var lower = 0, upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ranges[middle].end <= start { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }
}
