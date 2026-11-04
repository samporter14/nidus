import Testing
@testable import Nidus

struct ProtectionNoticeMemoryTests {
    @Test @MainActor func closedOrAlreadyBlockedBrowsersNeverInterrupt() {
        let candidates = ["org.mozilla.firefox", "app.zen-browser.zen", "com.apple.Safari"]
        #expect(UncoveredBrowsers.runningToOffer(candidates, running: [], blockedAsApp: { _ in false }).isEmpty)
        #expect(UncoveredBrowsers.runningToOffer(candidates, running: ["org.mozilla.firefox"],
                                                blockedAsApp: { _ in false }) == ["org.mozilla.firefox"])
        #expect(UncoveredBrowsers.runningToOffer(candidates, running: ["org.mozilla.firefox"],
                                                blockedAsApp: { _ in true }).isEmpty)
    }

    @Test func unchangedGapDoesNotInterruptAgain() {
        var memory = ProtectionNoticeMemory()
        let firefox = "unsupported:org.mozilla.firefox"
        #expect(memory.nextWarnings(for: [firefox]) == [firefox])
        memory.didPresent([firefox])
        #expect(memory.nextWarnings(for: [firefox]).isEmpty)
        #expect(memory.nextWarnings(for: [firefox]).isEmpty)
    }

    @Test func acknowledgementSurvivesRestartsButNewProblemDoesNotDisappear() {
        var memory = ProtectionNoticeMemory()
        let consent = "consent:com.google.Chrome"
        let denied = "denied:com.google.Chrome"
        memory.acknowledge([consent])
        var restarted = ProtectionNoticeMemory(acknowledged: memory.acknowledged)
        #expect(restarted.nextWarnings(for: [consent]).isEmpty)
        #expect(restarted.nextWarnings(for: [consent, denied]) == [denied])
    }

    @Test func unacknowledgedGapCanWarnAfterItActuallyResolved() {
        var memory = ProtectionNoticeMemory()
        let firefox = "unsupported:org.mozilla.firefox"
        memory.didPresent([firefox])
        #expect(memory.nextWarnings(for: []).isEmpty)
        #expect(memory.nextWarnings(for: [firefox]) == [firefox])
        memory.acknowledge([firefox])
        #expect(memory.nextWarnings(for: []).isEmpty)
        #expect(memory.nextWarnings(for: [firefox]).isEmpty)
    }

    @Test func acknowledgementStorageIsBounded() {
        var memory = ProtectionNoticeMemory()
        memory.acknowledge((0..<200).map { "unsupported:browser.\($0)" })
        #expect(memory.acknowledged.count == ProtectionNoticeMemory.limit)
        #expect(memory.acknowledged.last == "unsupported:browser.199")
    }
}
