import Foundation
import Testing
@testable import Nidus

@MainActor
struct FocusFileCompatibilityTests {
    @Test func capsidHoldsCardsDuringSystemPauseButNotManualPauseOrQuit() throws {
        let h = Harness()
        h.engine.start(plan(25))
        let running = FocusFile.snapshot(session: h.engine.session)
        #expect(running.focusing)
        #expect(running.until != nil)
        #expect(running.away == nil)
        var session = try #require(h.engine.session)
        session.phase = .paused(remaining: 1200, bySleep: true)
        let away = FocusFile.snapshot(session: session)
        #expect(!away.focusing)
        #expect(away.away == true)
        #expect(away.until == nil)
        session.phase = .paused(remaining: 1200, bySleep: false)
        #expect(FocusFile.snapshot(session: session).away == nil)
        session.phase = .paused(remaining: 1200, bySleep: true)
        let quit = FocusFile.snapshot(session: session, quitting: true)
        #expect(!quit.focusing && quit.away == nil && quit.until == nil)
        #expect(FocusFile.snapshot(session: nil).away == nil)
    }

    @Test func oldV1FilesStillDecodeAndNoActivityIsPublished() throws {
        let old = try JSONDecoder().decode(FocusFile.self, from: Data(#"{"version":1,"focusing":false}"#.utf8))
        #expect(old.away == nil)
        let data = try JSONEncoder().encode(FocusFile(version: 1, focusing: false, away: true))
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(fields.keys) == ["version", "focusing", "away"])
    }
}
