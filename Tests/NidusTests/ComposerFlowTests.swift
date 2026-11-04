import Foundation
import Testing
@testable import Nidus

struct ResumeChoiceTests {
    @Test func currentProjectComesFirstButEveryWaitingNoteRemainsReachable() {
        let project = UUID()
        let older = ResumeNote(text: "Continue the outline", projectID: project, createdAt: Date(timeIntervalSince1970: 10))
        let projectless = ResumeNote(text: "Book a room", createdAt: Date(timeIntervalSince1970: 30))
        let other = ResumeNote(text: "Review a draft", projectID: UUID(), createdAt: Date(timeIntervalSince1970: 20))
        let dismissed = ResumeNote(text: "Already done", projectID: project, dismissedAt: Date())
        let ordered = ResumeChoices.ordered([projectless, dismissed, other, older], projectID: project)
        #expect(ordered.map(\.id) == [older.id, projectless.id, other.id])
        #expect(ResumeChoices.suggested(in: ordered, selectedID: projectless.id) == projectless)
        #expect(ResumeChoices.suggested(in: ordered, selectedID: dismissed.id) == older)
        #expect(ResumeChoices.ordered([older, projectless, other], projectID: nil).first == projectless)
        #expect(!projectless.isDismissed && !older.isDismissed)
    }
}

@MainActor
struct SetupComposerTests {
    @Test func changingGoalAndLengthRetainsEverySetupOverride() {
        let project = FocusProject(name: "Research")
        let category = FocusCategory(id: "video", name: "Video", symbol: "play", apps: [], websites: ["video.example"])
        let resource = WorkspaceResource(kind: .webPage, displayName: "Notes", url: "https://example.org/notes")
        let setup = FocusSetup(name: "Writing", minutes: 90, categoryIDs: [category.id], mode: .block,
                               strict: true, goal: "Original goal", launchApps: [], startShortcut: "",
                               endShortcut: "Finished", websiteExceptions: [.init(kind: .exact, address: "video.example/class")],
                               resources: [resource], project: .project(project.id), breakMinutes: 0,
                               breakRules: BreakRules(reminder: "Stretch"))
        let draft = SetupComposerDraft(setup: setup, categories: [category], goal: "", project: nil, projects: [project])
        let edited = draft.composing(goal: "Just the introduction", minutes: 40, fixedEnd: false)
        var expected = setup.startRequest(categories: [category], goalDraft: "Just the introduction",
                                          popoverProject: nil, projects: [project])
        expected.minutes = 40
        #expect(edited == expected)
        #expect(draft.source == setup)
        #expect(setup.minutes == 90 && setup.goal == "Original goal")
        #expect(edited.launchApps == [] && edited.startShortcut == "" && edited.breakMinutes == 0)
        #expect(edited.resources == [resource] && edited.strict == true)
    }

    @Test func composerEditsAreTemporaryAndPreviewUsesTheSameRequest() throws {
        let model = NidusModel()
        model.goalDraft = "A thought already here"
        let defaults = model.durationMinutes
        let selected = model.selectedCategoryIDs
        let setup = FocusSetup(name: "Reading", minutes: 90, categoryIDs: ["news"], strict: true,
                               resources: [.init(kind: .webPage, displayName: "Guide", url: "https://example.org")],
                               breakMinutes: 12)
        #expect(model.prepareSetup(setup))
        #expect(!model.isActive)
        #expect(model.composerMinutes == 90 && model.composerStrict)
        model.choosePopoverLength(40)
        model.goalDraft = "Read chapter two"
        let request = model.popoverRequest()
        #expect(request.minutes == 40 && request.goal == "Read chapter two")
        #expect(request.categoryIDs == ["news"] && request.resources == setup.resources)
        #expect(request.breakMinutes == 12 && request.strict == true)
        let preview = try #require(model.sessionPreview())
        #expect(preview.summary.contains("40 min") && preview.summary.contains("News"))
        #expect(!preview.summary.contains("Social"))
        #expect(model.durationMinutes == defaults && model.selectedCategoryIDs == selected)
        #expect(model.setupDraft?.source == setup)
        model.discardSetupDraft()
        #expect(model.setupDraft == nil && model.goalDraft == "A thought already here")
        #expect(model.composerMinutes == defaults)
    }

    @Test func customLengthAndGoalClauseOverrideOnlyThePreparedSession() {
        let model = NidusModel()
        let setup = FocusSetup(name: "Writing", minutes: 90, categoryIDs: ["social"], breakMinutes: 10)
        #expect(model.prepareSetup(setup))
        model.openCustomLength()
        model.customLengthDraft?.text = "40"
        #expect(model.commitCustomLength())
        #expect(model.composerMinutes == 40 && model.durationMinutes == 25)
        model.goalDraft = "Outline for 15m"
        #expect(model.popoverRequest().minutes == 15)
        #expect(model.popoverRequest().goal == "Outline")
        #expect(model.setupDraft?.source.minutes == 90)
        #expect(model.fallbackMinutes(for: SessionRequest()) == 25,
                "An unrelated external request must not inherit a temporary setup")
    }

    @Test func switchingSetupsReplacesAnInheritedGoalButKeepsATypedGoal() {
        let first = FocusSetup(name: "Writing", goal: "Draft the outline")
        let second = FocusSetup(name: "Reading", goal: "Read chapter one")
        let model = NidusModel()
        #expect(model.prepareSetup(first))
        #expect(model.goalDraft == "Draft the outline")
        #expect(model.prepareSetup(second))
        #expect(model.goalDraft == "Read chapter one")
        model.goalDraft = "Read chapter two"
        #expect(model.prepareSetup(first))
        #expect(model.goalDraft == "Read chapter two")
        #expect(model.prepareSetup(second))
        #expect(model.goalDraft == "Read chapter two")
        model.discardSetupDraft()
        #expect(model.goalDraft.isEmpty)
        #expect(first.goal == "Draft the outline" && second.goal == "Read chapter one")
    }

    @Test func preparedSetupWithAFixedEndKeepsItsWorkspaceAndSuppressesTheBreak() throws {
        let model = NidusModel()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let setup = FocusSetup(name: "Writing", minutes: 90, categoryIDs: ["social"], strict: true,
                               resources: [.init(kind: .webPage, displayName: "Notes", url: "https://example.org")],
                               breakMinutes: 10)
        #expect(model.prepareSetup(setup))
        model.untilTarget = now.addingTimeInterval(40 * 60)
        let request = model.popoverRequest(now: now)
        #expect(request.minutes == 40 && request.hasFixedEnd)
        let resolved = try #require(request.resolved(with: model.startDefaults, length: { (25, false) }))
        #expect(resolved.plan.breakLength == 0)
        #expect(resolved.plan.strict && resolved.plan.resources == setup.resources)
        #expect(model.startTitle(now: now) == .plain,
                "The accessible Start label must not promise a break the preview and session suppress")
    }

    @Test func preparationCannotReplaceAnActiveSession() throws {
        let fixture = InboxFixture()
        fixture.inbox.add(text: "Something else")
        let item = try #require(fixture.inbox.openItems.first)
        // An unattached controller: no watchers, workspace hooks or real data.
        let controller = FocusController(directory: fixture.directory, now: { fixture.clock.now })
        controller.engine.start(SessionPlan(goal: "Current task", duration: 1500, mode: .block, apps: [], websites: [], strict: true))
        let model = NidusModel()
        model.adoptForTesting(controller: controller)
        model.inbox = fixture.inbox
        model.goalDraft = "Keep this draft"
        let before = controller.engine.session
        #expect(!model.prepareSetup(FocusSetup(name: "Other")))
        #expect(!model.prepareInboxGoal(item.id))
        #expect(model.goalDraft == "Keep this draft" && model.setupDraft == nil)
        #expect(controller.engine.session == before)
        #expect(fixture.inbox.item(item.id) == item)
    }

    @Test func preparingAnInboxGoalDoesNotOpenCompleteOrStartAnything() throws {
        let fixture = InboxFixture()
        _ = fixture.inbox.add(text: "Read the paper", link: "https://example.org/paper")
        let item = try #require(fixture.inbox.openItems.first)
        let model = NidusModel()
        model.inbox = fixture.inbox
        var opened: [URL] = []
        model.inboxURLOpener = { opened.append($0) }
        model.urlOpener = { opened.append($0); return true }
        #expect(model.prepareInboxGoal(item.id))
        #expect(model.goalDraft == "Read the paper")
        #expect(model.composerFocusRequest == 1)
        #expect(fixture.inbox.item(item.id) == item)
        #expect(opened.isEmpty && !model.isActive)
        model.setInboxItem(item.id, completed: true)
        model.goalDraft = "Keep this"
        #expect(!model.prepareInboxGoal(item.id))
        #expect(model.goalDraft == "Keep this")
    }
}
