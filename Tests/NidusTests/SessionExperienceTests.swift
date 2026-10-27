import AppKit
import SwiftUI
import Testing
@testable import Nidus

@MainActor
struct SessionPreviewTests {
    private let categories = [FocusCategory(id: "social", name: "Social", symbol: "person.2", apps: [], websites: ["x.com"])]

    @Test func previewUsesResolvedOverridesAndFixedEndsSuppressTheBreak() throws {
        let defaults = StartDefaults(mode: .block, selectedCategoryIDs: ["social"], categories: categories,
                                     strict: true, defaultBreakLength: 300)
        let request = SessionRequest(goal: "Write", minutes: 45)
        let resolved = try #require(request.resolved(with: defaults, length: { Issue.record("unexpected length read"); return (25, false) }))
        let preview = SessionPreview(plan: resolved.plan, categoryNames: ["Social"])
        #expect(preview.summary == "45 min · Social blocked · 5 min break")
        #expect(preview.details.contains { $0.text.contains("Strict: no pause or snooze") })

        let fixed = try #require(SessionRequest(goal: "Write", hasFixedEnd: true).resolved(with: defaults, length: { (30, false) }))
        #expect(SessionPreview(plan: fixed.plan, categoryNames: ["Social"]).summary == "30 min · Social blocked")
    }

    @Test func anOpenEndedPlanDoesNotPromiseAnAutomaticBreak() {
        var plan = SessionPlan(goal: "", duration: nil, mode: .allow, apps: [], websites: [])
        plan.breakLength = 300
        let preview = SessionPreview(plan: plan, categoryNames: [])
        #expect(preview.summary == "Open-ended · Allow list")
        #expect(!preview.details.contains { $0.symbol == NidusSymbols.rest })
    }

    @Test func previewShowsBreakRulesAndInheritedActionsOnlyFromTheResolvedPlan() throws {
        let defaults = StartDefaults(mode: .block, selectedCategoryIDs: ["social"], categories: categories,
                                     launchApps: ["org.example.Editor"], startShortcut: "Focus on", endShortcut: "Focus off",
                                     defaultBreakLength: 600, defaultBreakRules: BreakRules(websites: ["x.com"], reminder: "Water"))
        let resolved = try #require(SessionRequest(goal: "", minutes: 25).resolved(with: defaults, length: { (25, false) }))
        let details = SessionPreview(plan: resolved.plan, categoryNames: ["Social"]).details.map(\.text)
        #expect(details.contains("Break block list: 0 apps · 1 website."))
        #expect(details.contains("Water"))
        #expect(details.contains("At start: Focus on") && details.contains("At end: Focus off"))
        #expect(details.contains("Opens 1 app when focus starts."))
    }

    @Test func typingALengthPreviewsTheSameLengthWithoutStartingOrChangingTheDraft() throws {
        let model = NidusModel()
        model.goalDraft = "Write for 45m"
        let preview = try #require(model.sessionPreview())
        #expect(preview.summary.hasPrefix("45 min · "))
        #expect(model.goalDraft == "Write for 45m")
        #expect(model.durationMinutes == 25 && model.engine == nil)
        #expect(model.lengthLabel == "45 min")
        #expect(model.isPopoverLength(45) && !model.isPopoverLength(25))
    }

    @Test func choosingALengthReplacesTheGoalOverrideButKeepsOrdinaryGoalWords() {
        let model = NidusModel()
        model.goalDraft = "Write for 45m"
        model.choosePopoverLength(25)
        #expect(model.goalDraft == "Write")
        #expect(model.popoverRequest().minutes == nil)
        #expect(model.isPopoverLength(25))
        model.goalDraft = "Plan for next week"
        model.choosePopoverLength(25)
        #expect(model.goalDraft == "Plan for next week")
    }

    @Test func aCustomLengthAlsoReplacesTheGoalOverride() {
        let model = NidusModel()
        model.goalDraft = "Write for 45m"
        model.customLengthDraft = CustomLengthDraft(text: "until 3:30pm")
        #expect(model.commitCustomLength(now: FocusDurationParserTests.at(12)))
        #expect(model.goalDraft == "Write" && model.untilTarget != nil)
        #expect(model.popoverRequest().minutes == nil)
    }

    @Test func previewKeepsTheMeetingChoiceAndDoesNotRefreshTheCalendar() throws {
        let now = FocusDurationParserTests.at(12)
        let source = FakeCalendarSource(events: [CalendarEvent(title: "Meeting", start: now.addingTimeInterval(2400),
                                                              end: now.addingTimeInterval(6000))])
        let model = NidusModel()
        model.meetings.source = source
        model.meetings.calendar = FocusDurationParserTests.utc
        model.meetings.refresh(now: now)
        model.meetings.isChosen = true
        // A fresh calendar read would now return no meeting.
        source.events = []
        for _ in 0..<3 {
            #expect(try #require(model.sessionPreview(now: now)).summary.hasPrefix("40 min · "))
        }
        #expect(model.meetings.isChosen)
        #expect(model.meetings.next?.title == "Meeting")
        #expect(source.requestCount == 0)
    }
}

@MainActor
struct UnnamedSessionNextStepTests {
    @Test(arguments: ["", "   ", "Write"])
    func anySessionLongEnoughToCountCanLeaveANote(goal: String) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-session-experience-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ResumeNoteStore(url: folder.appendingPathComponent(ResumeNoteStore.fileName))
        let model = NidusModel()
        model.resumeNotes = store
        let plan = SessionPlan(goal: goal, duration: 1500, mode: .block, apps: [], websites: [])
        var final = SessionState(plan: plan, startedAt: Date(), phase: .running(deadline: Date()), budget: 1500)
        final.focusedTime = SessionEntry.minimumFocus - 1
        #expect(model.beginNextStep(for: final, entry: nil) == nil)
        final.focusedTime = SessionEntry.minimumFocus
        let entry = try #require(SessionEntry(ended: final, outcome: .endedEarly))
        let step = try #require(model.beginNextStep(for: final, entry: entry))
        #expect(store.notes.isEmpty, "showing the field does not create a note")
        step.setText("Check the results")
        let note = try #require(ResumeNoteStore(url: store.url).notes.first)
        #expect(note.goal == goal && note.entryID == entry.id)
        #expect(note.sessionGoal == "Check the results")
        #expect(entry.finished == nil, "no finish answer is invented")
        step.discard()
        #expect(store.notes.isEmpty, "Undo can take an unnamed session's note back too")
    }
}

@MainActor
struct SessionExperienceLayoutTests {
    /// Also exports flat review images when NIDUS_SESSION_SNAPSHOTS is set.
    /// NSHostingView needs no app launch or access to the user's settings.
    @Test func newSurfacesFitTheCompactPopoverAndCard() throws {
        let model = NidusModel()
        model.meetings.source = FakeCalendarSource(access: .notDetermined)
        model.goalDraft = "Write the next chapter for 45m"
        var plan = SessionPlan(goal: "", duration: 2700, mode: .block, apps: [], websites: ["x.com"])
        plan.breakLength = 300
        plan.strict = true
        let preview = SessionPreview(plan: plan, categoryNames: ["Social"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let step = NextStepSession(seed: .init(goal: ""), historyIsOff: true,
                                   store: ResumeNoteStore(url: folder.appendingPathComponent(ResumeNoteStore.fileName)))
        let views: [(String, CGFloat, AnyView)] = [
            ("composer", 440, AnyView(NidusPopover(model: model))),
            ("plan-details", 370, AnyView(SessionPreviewRow(preview: preview, expanded: true))),
            ("unnamed-finish", 388, AnyView(FocusWrapUpCard(title: "Session complete", detail: "45 min focused",
                mediumDetail: "45 min focused", shortDetail: "45 min", completed: true, nextStep: step, again: {}))),
        ]
        for (name, width, view) in views {
            for (theme, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua), ("dark", .dark, .darkAqua)] {
                let root = view.frame(width: width).padding(16).background(Solanum.page).environment(\.colorScheme, scheme)
                let hosting = NSHostingView(rootView: root)
                hosting.appearance = NSAppearance(named: appearance)
                hosting.frame = NSRect(x: 0, y: 0, width: width + 32, height: 10)
                let size = hosting.fittingSize
                #expect(size.width <= width + 32 && size.height > 0 && size.height < 700, "\(name)-\(theme): \(size)")
                if let path = ProcessInfo.processInfo.environment["NIDUS_SESSION_SNAPSHOTS"] {
                    let directory = URL(fileURLWithPath: path, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    hosting.frame.size = size
                    hosting.layoutSubtreeIfNeeded()
                    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: directory.appendingPathComponent("\(name)-\(theme).png"))
                }
            }
        }
    }
}
