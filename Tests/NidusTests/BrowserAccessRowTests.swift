import Testing
@testable import Nidus

/// The browser row's answer is read off the main thread now; what it shows for
/// each answer is unchanged.
@MainActor
struct BrowserAccessRowTests {
    @Test func eachAnswerReadsAsBefore() {
        #expect(BrowserAccessRow.status(for: nil) == .allowed)
        #expect(BrowserAccessRow.status(for: .needsConsent) == .notAsked)
        #expect(BrowserAccessRow.status(for: .notPermitted) == .denied)
        #expect(BrowserAccessRow.status(for: .notRunning) == .notRunning)
        #expect(BrowserAccessRow.status(for: .failed(-1)) == .unknown)
    }
}
