import AppKit
import Combine
import Testing
@testable import Nidus

@MainActor
struct SettingsClockTests {
    private func settingsWindow() -> NSWindow {
        SettingsWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled], backing: .buffered, defer: true)
    }

    private func panel() -> NSWindow {
        NSPanel(contentRect: .init(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: true)
    }

    private func watched(_ fixture: InboxFixture, showing windows: [NSWindow]) -> (NidusModel, FocusController) {
        let controller = FocusController(directory: fixture.directory, now: { fixture.clock.now })
        let model = NidusModel()
        model.adoptForTesting(controller: controller)
        model.shownWindows = { windows }
        model.forwardChanges(of: controller)
        return (model, controller)
    }

    @Test func aPlainSecondSkipsSettingsAlone() {
        #expect(NidusModel.onlySettingsIsShowing([settingsWindow()]))
        #expect(!NidusModel.onlySettingsIsShowing([settingsWindow(), panel()]))
        #expect(!NidusModel.onlySettingsIsShowing([panel()]))
        #expect(!NidusModel.onlySettingsIsShowing([]))

        let fixture = InboxFixture()
        let (model, controller) = watched(fixture, showing: [settingsWindow()])
        var sent = 0
        let watching = model.objectWillChange.sink { sent += 1 }
        defer { watching.cancel() }
        controller.tick()
        #expect(sent == 0)
        controller.bumpActivityDayVersion()
        #expect(sent == 1)
    }

    @Test func aSecondStillReachesAnythingElseShowing() {
        for windows in [[settingsWindow(), panel()], [panel()], []] {
            let fixture = InboxFixture()
            let (model, controller) = watched(fixture, showing: windows)
            var sent = 0
            let watching = model.objectWillChange.sink { sent += 1 }
            controller.tick()
            watching.cancel()
            #expect(sent == 1)
        }
    }

    @Test func aSessionEndingOnATickReachesSettings() {
        let fixture = InboxFixture()
        let (model, controller) = watched(fixture, showing: [settingsWindow()])
        controller.engine.start(SessionPlan(goal: "Short", duration: 60, mode: .block, apps: [], websites: []))
        var sent = 0
        let watching = model.objectWillChange.sink { sent += 1 }
        defer { watching.cancel() }
        fixture.clock.now = fixture.clock.now.addingTimeInterval(120)
        controller.tick()
        #expect(controller.engine.session == nil)
        #expect(sent > 0)
    }
}
