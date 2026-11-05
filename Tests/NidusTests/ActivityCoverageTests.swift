import Foundation
import Testing
@testable import Nidus

struct ActivityCoverageTests {
    private let base = Date(timeIntervalSince1970: 1_735_689_600)
    private func segment(_ from: Double, _ to: Double, id: String = "source") -> FocusActivitySegment {
        FocusActivitySegment(id: id, start: base.addingTimeInterval(from), end: base.addingTimeInterval(to),
                             appID: "word", appName: "Word", site: "Microsoft Word", title: "Draft",
                             url: "https://word.cloud.microsoft/draft", continuity: 7)
    }

    private func coverage(_ segments: some Sequence<FocusActivitySegment>) -> ActivityCoverage {
        ActivityCoverage(intervals: segments.map { DateInterval(start: $0.start, end: $0.end) })
    }

    @Test func overlappingAndTouchingCoverageIsUnitedWithoutFillingGaps() {
        let original = segment(0, 100)
        let known = coverage([segment(80, 110), segment(30, 50), segment(10, 35), segment(50, 60)])
        let missing = known.uncovered([original])
        #expect(missing.map { $0.start.timeIntervalSince(base) } == [0, 60])
        #expect(missing.map { $0.end.timeIntervalSince(base) } == [10, 80])
        #expect(missing.reduce(0) { $0 + $1.seconds } == 30)
        #expect(Set(missing.map(\.id)).count == 2)
        for piece in missing {
            #expect(piece.appID == original.appID && piece.appName == original.appName)
            #expect(piece.site == original.site && piece.title == original.title && piece.url == original.url)
            #expect(piece.continuity == original.continuity)
        }
    }

    @Test func touchingEndpointsLeaveTheObservationUnchanged() {
        let original = segment(10, 20)
        #expect(coverage([segment(0, 10), segment(20, 30)]).uncovered([original]) == [original])
        #expect(coverage([segment(0, 30)]).uncovered([original]).isEmpty)
        #expect(coverage([]).uncovered([original]) == [original])
    }

    @Test func overlapsIgnoresIntervalsThatOnlyTouch() {
        let known = coverage([segment(10, 20), segment(40, 50)])
        func interval(_ from: Double, _ to: Double) -> DateInterval {
            DateInterval(start: base.addingTimeInterval(from), end: base.addingTimeInterval(to))
        }
        #expect(known.overlaps(interval(15, 30)))
        #expect(known.overlaps(interval(0, 100)))
        #expect(!known.overlaps(interval(20, 40)))
        #expect(!known.overlaps(interval(60, 70)))
    }

    @Test func coverageMatchesAnExhaustiveSecondsReference() {
        let observed = (0..<40).map { index in
            let from = Double((index * 29) % 200)
            return segment(from, from + Double(index % 9 + 1), id: "cover-\(index)")
        }.reversed()
        let known = coverage(observed)
        for offset in stride(from: 0, through: 200, by: 11) {
            let input = segment(Double(offset), Double(offset + 10))
            let expected = (offset..<(offset + 10)).filter { second in
                let instant = base.addingTimeInterval(Double(second) + 0.5)
                return !observed.contains { $0.start <= instant && $0.end > instant }
            }.count
            #expect(known.uncovered([input]).reduce(0) { $0 + $1.seconds } == Double(expected))
        }
    }
}
