//
//  PopoverQualityTests.swift
//  NidusTests
//
//  Small things in the idle popover: a length typed at the end of the goal,
//  the Start button saying a break follows, the offer to save a plan started
//  by hand again and again, and Return in the goal field.
//

import Foundation
import Testing
@testable import Nidus

// MARK: - A length typed in the goal

struct GoalLengthClauseTests {
    static func split(_ text: String, now: Date = FocusDurationParserTests.at(15)) -> GoalLengthClause? {
        GoalLengthClause.split(text, now: now, calendar: FocusDurationParserTests.utc)
    }

    @Test(arguments: [
        ("Aims for 45m", "Aims", 45), ("Aims for 1h30", "Aims", 90), ("Aims for 45 min", "Aims", 45),
        ("Aims for 1.5 hours", "Aims", 90), ("Aims for 1:30", "Aims", 90), ("Aims FOR 2H", "Aims", 120),
        ("  Write the launch post   for   25m  ", "Write the launch post", 25),
    ])
    func forTakesALengthWithItsUnit(text: String, goal: String, minutes: Int) {
        let clause = Self.split(text)
        #expect(clause == GoalLengthClause(goal: goal, length: .minutes(minutes)), "\(text)")
    }

    @Test func untilTakesATimeOfDay() throws {
        // 15:00 UTC on 25 September: "until 3" is 3 in the morning or the
        // afternoon, whichever is next, as in the Custom… field.
        let now = FocusDurationParserTests.at(15)
        for (text, hour, minute, day) in [("Aims until 3", 3, 0, 26), ("Aims until 3:30pm", 15, 30, 25),
                                          ("Aims until 15:30", 15, 30, 25), ("Aims till 5pm", 17, 0, 25),
                                          ("Aims UNTIL 3PM", 15, 0, 26)] {
            let clause = try #require(Self.split(text, now: now), "\(text)")
            #expect(clause.goal == "Aims", "\(text)")
            #expect(clause.length == .until(FocusDurationParserTests.at(hour, minute, day: day)), "\(text)")
        }
    }

    @Test func aTimeOfDayBecomesMinutesAtStart() throws {
        let now = FocusDurationParserTests.at(15)
        let clause = try #require(Self.split("Aims until 3:30pm", now: now))
        #expect(clause.minutes(now: now) == 30)
        #expect(clause.minutes(now: now.addingTimeInterval(10 * 60)) == 20, "worked out at Start, not when typed")
        #expect(GoalLengthClause(goal: "Aims", length: .minutes(45)).minutes() == 45)
    }

    @Test(arguments: [
        "Wait for the build", "Plan the trip for two weeks", "Read until the end", "Study for the exam",
        "Aims", "Aims for", "Aims for 45", "Chapter for 3", "Aims until", "Aims until noon", "Aims until 25",
        "Aims for 0m", "Aims for 25h", "Aims for 45m please", "Aims, 45m", "Aims 45m", "Fix format for 45minutes of x",
        "for 45m", "until 3pm", "  for 45m", "Aims for 3pm", "Aims until 45m", "Formatting for 1h30 and 20m",
    ])
    func anythingElseIsLeftAlone(text: String) {
        #expect(Self.split(text) == nil, "\(text)")
    }

    @Test func onlyTheTrailingClauseCounts() throws {
        let clause = try #require(Self.split("Revise the intro for reviewers until 5pm"))
        #expect(clause.goal == "Revise the intro for reviewers")
        #expect(Self.split("Revise until 5pm for reviewers") == nil, "the clause is not at the end")
        // A "for" inside the goal does not stop the trailing one being read.
        #expect(Self.split("Plan for 2026 for 45m")?.goal == "Plan for 2026")
    }

    @Test func theChipReadsTheLength() throws {
        let utc = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        #expect(GoalLengthClause(goal: "Aims", length: .minutes(90)).lengthLabel(locale: locale, timeZone: utc) == "1 hr 30 min")
        let until = GoalLengthClause(goal: "Aims", length: .until(FocusDurationParserTests.at(15, 30)))
        #expect(until.lengthLabel(locale: locale, timeZone: utc).hasPrefix("Until 3:30"))
    }
}

// MARK: - Return in the goal field

@MainActor
struct PopoverStartRequestTests {
    let categories = [FocusCategory(id: "social", name: "Social", symbol: "person.2", apps: [], websites: ["x.com"]),
                      FocusCategory(id: "empty", name: "Empty", symbol: "circle", apps: [], websites: [])]

    func defaults(selected: [String]) -> StartDefaults {
        StartDefaults(mode: .block, selectedCategoryIDs: selected, categories: categories)
    }

    @Test func aLengthInTheGoalIsThisStartsLengthAndTheGoalKeptIsWithoutIt() throws {
        let model = NidusModel()
        model.goalDraft = "Aims for 45m"
        let request = model.popoverRequest()
        #expect(request.goal == "Aims")
        #expect(request.minutes == 45)
        let plan = try #require(request.resolved(with: defaults(selected: ["social"]), length: { (25, false) })?.plan)
        #expect(plan.goal == "Aims")
        #expect(plan.duration == TimeInterval(45 * 60))
    }

    @Test func aGoalWithoutOneStartsAsTyped() throws {
        let model = NidusModel()
        model.goalDraft = "Wait for the build"
        let request = model.popoverRequest()
        #expect(request.goal == "Wait for the build")
        #expect(request.minutes == nil, "the Length choice decides")
        let plan = try #require(request.resolved(with: defaults(selected: ["social"]), length: { (25, false) })?.plan)
        #expect(plan.duration == TimeInterval(25 * 60))
    }

    @Test func untilBecomesMinutesFromNow() throws {
        let model = NidusModel()
        let now = Date()
        model.goalDraft = "Aims until 11:59pm"
        let minutes = try #require(model.popoverRequest(now: now).minutes)
        #expect((1...1440).contains(minutes))
    }

    @Test func returnRefusesWhenItWouldBlockNothing() {
        // Return, the Start button and the menu all make this request, and
        // the one resolution refuses a block list with nothing in it.
        let model = NidusModel()
        model.goalDraft = "Aims for 45m"
        let request = model.popoverRequest()
        #expect(request.resolved(with: defaults(selected: ["empty"]), length: { (25, false) }) == nil)
        #expect(request.resolved(with: defaults(selected: []), length: { (25, false) }) == nil)
        // With no session engine to start on, the model refuses too, and
        // starts nothing.
        #expect(model.startSession(request) == false)
        #expect(!model.isActive)
    }
}

// MARK: - The Start button says a break follows

@MainActor
struct StartTitleTests {
    @Test func aTimedSessionWithABreakSaysBoth() {
        let title = StartTitle.make(length: 25, breakMinutes: 5)
        #expect(title.text == "Start focus \u{00B7} 25 + 5 min break")
        #expect(title.spoken == "Start focus, 25 minutes, then a 5 minute break")
        #expect(StartTitle.make(length: 50, breakMinutes: 10).text == "Start focus \u{00B7} 50 + 10 min break")
    }

    @Test func aLongSessionKeepsItsUnits() {
        #expect(StartTitle.make(length: 90, breakMinutes: 15).text == "Start focus \u{00B7} 90 + 15 min break")
        #expect(StartTitle.make(length: 120, breakMinutes: 5).text == "Start focus \u{00B7} 2 hr + 5 min break")
        #expect(StartTitle.make(length: 187, breakMinutes: 5).text == "Start focus \u{00B7} 3 hr 7 min + 5 min break")
    }

    @Test func anEndTimeIsSaidAsOne() {
        let title = StartTitle.make(length: 0, until: "3:30 PM", breakMinutes: 5)
        #expect(title.text == "Start focus \u{00B7} until 3:30 PM + 5 min break")
    }

    @Test func nothingIsSaidWhenNoBreakFollows() {
        #expect(StartTitle.make(length: 25, breakMinutes: 0) == .plain, "no break chosen")
        #expect(StartTitle.make(length: 0, breakMinutes: 5) == .plain, "open-ended: nothing to follow")
        #expect(StartTitle.make(length: 40, breakMinutes: 5, fixedEnd: true) == .plain, "until the next meeting")
        #expect(StartTitle.plain.text == "Start focus")
    }

    @Test func theModelReadsTheGoalTheLengthAndSettings() {
        // Without Settings (no host) the break is none: the plain button.
        let model = NidusModel()
        #expect(model.startTitle() == .plain)
        model.goalDraft = "Aims for 45m"
        #expect(model.startTitle() == .plain)
    }
}

// MARK: - Save this as a setup

@MainActor
struct SetupSuggestionTests {
    static let now = FocusDurationParserTests.at(12)
    static let plan = PlanSignature(minutes: 25, categoryIDs: ["video", "social"], mode: .block)

    static func starts(_ plan: PlanSignature, daysAgo: [Double]) -> [PlanStart] {
        daysAgo.map { PlanStart(plan: plan, at: now.addingTimeInterval(-$0 * 86_400)) }
    }

    @Test func theOrderOfCategoriesDoesNotMakeAnotherPlan() {
        #expect(Self.plan == PlanSignature(minutes: 25, categoryIDs: ["social", "video"], mode: .block))
        #expect(Self.plan != PlanSignature(minutes: 50, categoryIDs: ["social", "video"], mode: .block))
        #expect(Self.plan != PlanSignature(minutes: 25, categoryIDs: ["social"], mode: .block))
        #expect(Self.plan != PlanSignature(minutes: 25, categoryIDs: ["social", "video"], mode: .allow))
    }

    @Test func threeRecentStartsOfThePlanOfferIt() {
        let starts = Self.starts(Self.plan, daysAgo: [0.1, 1, 6])
        #expect(SetupSuggestion.shouldOffer(current: Self.plan, starts: starts, dismissed: [], hasSetups: false, now: Self.now))
        #expect(!SetupSuggestion.shouldOffer(current: Self.plan, starts: Array(starts.prefix(2)), dismissed: [],
                                             hasSetups: false, now: Self.now), "twice is not a habit")
    }

    @Test func startsOutsideTheWindowOrOfOtherPlansDoNotCount() {
        let other = PlanSignature(minutes: 50, categoryIDs: ["social"], mode: .block)
        let starts = Self.starts(Self.plan, daysAgo: [0.1, 1, 20]) + Self.starts(other, daysAgo: [0.2, 0.3, 0.4, 0.5])
        #expect(!SetupSuggestion.shouldOffer(current: Self.plan, starts: starts, dismissed: [], hasSetups: false, now: Self.now))
        #expect(SetupSuggestion.shouldOffer(current: other, starts: starts, dismissed: [], hasSetups: false, now: Self.now))
    }

    @Test func onlyThePlanInHandIsOffered() {
        let starts = Self.starts(Self.plan, daysAgo: [0.1, 1, 2])
        let different = PlanSignature(minutes: 40, categoryIDs: ["social"], mode: .block)
        #expect(!SetupSuggestion.shouldOffer(current: different, starts: starts, dismissed: [], hasSetups: false, now: Self.now))
        #expect(!SetupSuggestion.shouldOffer(current: nil, starts: starts, dismissed: [], hasSetups: false, now: Self.now),
                "an until time or a meeting is no plan to save")
    }

    @Test func aSavedSetupSilencesIt() {
        let starts = Self.starts(Self.plan, daysAgo: [0.1, 1, 2])
        #expect(!SetupSuggestion.shouldOffer(current: Self.plan, starts: starts, dismissed: [], hasSetups: true, now: Self.now))
    }

    @Test func dismissedStaysDismissedForThatPlanOnly() {
        let starts = Self.starts(Self.plan, daysAgo: [0.1, 1, 2])
        #expect(!SetupSuggestion.shouldOffer(current: Self.plan, starts: starts, dismissed: [Self.plan],
                                             hasSetups: false, now: Self.now))
        let other = PlanSignature(minutes: 50, categoryIDs: ["social"], mode: .block)
        let both = starts + Self.starts(other, daysAgo: [0.1, 1, 2])
        #expect(SetupSuggestion.shouldOffer(current: other, starts: both, dismissed: [Self.plan], hasSetups: false, now: Self.now))
    }

    @Test func recordingForgetsTheOldAndKeepsALimit() {
        let old = Self.starts(Self.plan, daysAgo: [30, 20])
        let recorded = SetupSuggestion.recording(Self.plan, at: Self.now, in: old)
        #expect(recorded.map(\.at) == [Self.now])

        var many: [PlanStart] = []
        for index in 0..<(SetupSuggestion.keepLast + 10) {
            many = SetupSuggestion.recording(Self.plan, at: Self.now.addingTimeInterval(Double(index)), in: many)
        }
        #expect(many.count == SetupSuggestion.keepLast)
        #expect(many.last?.at == Self.now.addingTimeInterval(Double(SetupSuggestion.keepLast + 9)))
    }

    @Test func theStartsSurviveBeingSaved() throws {
        let starts = Self.starts(Self.plan, daysAgo: [0.1, 1])
        let data = try JSONEncoder().encode(starts)
        #expect(try JSONDecoder().decode([PlanStart].self, from: data) == starts)
    }

    @Test func itIsTheLowestNudge() {
        #expect(IdleNudge.top(brickOffer: true, resumeNote: true, inbox: true, saveSetup: true) == .brick)
        #expect(IdleNudge.top(brickOffer: false, resumeNote: true, inbox: true, saveSetup: true) == .resume)
        #expect(IdleNudge.top(brickOffer: false, resumeNote: false, inbox: true, saveSetup: true) == .inbox)
        #expect(IdleNudge.top(brickOffer: false, resumeNote: false, inbox: false, saveSetup: true) == .saveSetup)
        #expect(IdleNudge.top(brickOffer: false, resumeNote: false, inbox: false, saveSetup: false) == nil)
        for bits in 0..<16 {
            let nudge = IdleNudge.top(brickOffer: bits & 1 != 0, resumeNote: bits & 2 != 0,
                                      inbox: bits & 4 != 0, saveSetup: bits & 8 != 0)
            #expect((nudge == nil) == (bits == 0), "never more than one")
        }
    }

    @Test func aModelWithNoHostOffersNothing() {
        let model = NidusModel()
        #expect(!model.offersSetupSuggestion())
        model.dismissSetupSuggestion()
        model.clearPlanStarts()
    }
}
