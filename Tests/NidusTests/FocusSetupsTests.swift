//
//  FocusSetupsTests.swift
//  NidusTests
//
//  Saved setups: what a setup asks the model to start, what happens to the
//  categories it names once some are deleted, which goal wins, the summary
//  line, and how the list is stored and ordered. The model itself is not
//  built here: it would open the real settings and folder.
//

import AppKit
import Foundation
import Testing
@testable import Nidus

struct FocusSetupTests {
    static let xcode = FocusCategory(id: "xcode", name: "Xcode", symbol: "hammer",
                                     apps: [BlockedApp(bundleID: "com.apple.dt.Xcode", name: "Xcode")], websites: [])
    static let blank = FocusCategory(id: "blank", name: "Blank", symbol: "square", apps: [], websites: [])
    /// Social, Messaging, Video, News and Mail, then Xcode and an empty one.
    static let categories = FocusCategory.presets + [xcode, blank]

    static func setup(_ ids: [String], mode: SessionPlan.Mode = .block, minutes: Int = 45,
                      strict: Bool = false, goal: String? = nil) -> FocusSetup {
        FocusSetup(name: "Test", minutes: minutes, categoryIDs: ids, mode: mode, strict: strict, goal: goal)
    }

    // MARK: Conversion to a request

    @Test func aSetupAsksForExactlyWhatItSays() {
        let request = Self.setup(["social", "video"], minutes: 45, strict: true, goal: "Draft")
            .request(categories: Self.categories)
        #expect(request == SessionRequest(goal: "Draft", minutes: 45, categoryIDs: ["social", "video"],
                                          mode: .block, strict: true))
    }

    @Test func noFieldIsLeftNilForThePopoverToFill() {
        // Nil would take the popover's current choice: a different session
        // from the one on the button.
        let open = Self.setup([], mode: .allow, minutes: 0).request(categories: Self.categories)
        #expect(open.minutes == 0, "open-ended is 0, not nil")
        #expect(open.categoryIDs == [], "no categories is empty, not nil")
        #expect(open.mode == .allow)
        #expect(open.strict == false)
    }

    @Test func aSetupAllowsSomethingTheSettingsDefaultDoesNot() {
        let request = Self.setup(["xcode"], mode: .allow, minutes: 90, strict: true).request(categories: Self.categories)
        #expect(request.mode == .allow)
        #expect(request.strict == true)
        #expect(request.minutes == 90)
    }

    // MARK: Categories deleted since

    @Test func missingCategoriesAreDroppedInTheSetupsOrder() {
        let request = Self.setup(["video", "deleted", "social"]).request(categories: Self.categories)
        #expect(request.categoryIDs == ["video", "social"])
    }

    @Test func aSetupWithNoCategoriesLeftAsksForNone() {
        let request = Self.setup(["gone", "also-gone"]).request(categories: Self.categories)
        #expect(request.categoryIDs == [])
    }

    @Test func theSetupItselfIsNotEditedByDroppingThem() {
        let setup = Self.setup(["social", "deleted"])
        _ = setup.request(categories: Self.categories)
        #expect(setup.categoryIDs == ["social", "deleted"])
    }

    @Test func blockModeWithNothingLeftCannotStart() {
        #expect(Self.setup(["gone"]).problem(in: Self.categories) == .categoriesGone)
        #expect(Self.setup([]).problem(in: Self.categories) == .nothingToBlock)
        #expect(Self.setup(["blank"]).problem(in: Self.categories) == .nothingToBlock,
                "a category that exists but is empty blocks nothing")
        #expect(Self.setup(["blank", "social"]).problem(in: Self.categories) == nil)
        #expect(Self.setup(["social", "gone"]).problem(in: Self.categories) == nil,
                "one left is enough")
    }

    @Test func anAllowListWhoseCategoriesAreAllGoneDoesNotStart() {
        // Allowing nothing would hide every app, which is not what a setup
        // saved to keep Xcode open means.
        #expect(Self.setup(["xcode"], mode: .allow).problem(in: []) == .categoriesGone)
        #expect(Self.setup(["xcode", "gone"], mode: .allow).problem(in: Self.categories) == nil,
                "one left: it allows what is left")
        #expect(Self.setup([], mode: .allow).problem(in: Self.categories) == nil,
                "saved with none on purpose, as the popover allows")
        #expect(Self.setup(["blank"], mode: .allow).problem(in: Self.categories) == nil,
                "startSession refuses only block lists with nothing in them")
    }

    /// `NidusModel.startSession` refuses a block list session whose chosen
    /// categories are all empty. A setup that would be refused there must
    /// already be dimmed here; if startSession's guard changes, this fails.
    @Test(arguments: [[], ["gone"], ["blank"], ["social"], ["blank", "social"], ["social", "gone"]] as [[String]])
    func theBarDimsEverythingStartSessionWouldRefuse(_ ids: [String]) {
        let setup = Self.setup(ids)
        let request = setup.request(categories: Self.categories)
        let chosen = Self.categories.filter { request.categoryIDs?.contains($0.id) == true }
        let refused = request.mode != .allow && chosen.allSatisfy(\.isEmpty)
        #expect(!refused || setup.problem(in: Self.categories) != nil)
    }

    // MARK: Which goal wins

    @Test func aGoalTypedInThePopoverBeatsTheSetupsOwn() {
        let setup = Self.setup(["social"], goal: "Saved goal")
        #expect(setup.request(categories: Self.categories, goalDraft: "Typed goal").goal == "Typed goal")
    }

    @Test func withNothingTypedTheSetupsGoalIsUsed() {
        let setup = Self.setup(["social"], goal: "Saved goal")
        #expect(setup.request(categories: Self.categories, goalDraft: "").goal == "Saved goal")
        #expect(setup.request(categories: Self.categories, goalDraft: "  \n ").goal == "Saved goal",
                "blank is not a goal")
    }

    @Test func withNeitherThereIsNoGoal() {
        #expect(Self.setup(["social"]).request(categories: Self.categories).goal == nil)
        #expect(Self.setup(["social"], goal: "  ").request(categories: Self.categories, goalDraft: "").goal == nil)
    }

    @Test func aTypedGoalIsTrimmed() {
        #expect(FocusSetup.resolvedGoal(typed: "  Write the intro \n", saved: "x") == "Write the intro")
    }

    // MARK: The summary

    @Test func theSummaryReadsLengthThenWhatItBlocks() {
        #expect(Self.setup(["social", "video"]).planSummary(categories: Self.categories) == "45 min · Social, Video")
    }

    @Test func anAllowListSaysOnlyAndStrictSaysSo() {
        // The length is written as the rest of the app writes it.
        #expect(Self.setup(["xcode"], mode: .allow, minutes: 90, strict: true).planSummary(categories: Self.categories)
                == "1 hr 30 min · Only Xcode · strict")
    }

    @Test func openEndedAndLongListsRead() {
        #expect(Self.setup(["social", "video", "news"], minutes: 0).planSummary(categories: Self.categories)
                == "Open-ended · 3 categories")
        #expect(Self.setup(["social", "video", "news"], mode: .allow).planSummary(categories: Self.categories)
                == "45 min · Only 3 categories")
    }

    @Test func theSummaryNamesCategoriesInTheirOwnOrderAndSkipsDeletedOnes() {
        #expect(Self.setup(["video", "gone", "social"]).planSummary(categories: Self.categories)
                == "45 min · Social, Video")
    }

    @Test func aSetupWithNothingInItSaysSo() {
        #expect(Self.setup(["gone"]).planSummary(categories: Self.categories) == "45 min · Nothing to block")
        #expect(Self.setup([], mode: .allow).planSummary(categories: Self.categories) == "45 min · Nothing allowed")
    }

    @Test func aClearedNameIsNeverAnEmptyButton() {
        var setup = Self.setup([])
        setup.name = "  "
        #expect(setup.displayName == "Untitled")
        setup.name = " Deep work "
        #expect(setup.displayName == "Deep work")
    }

    // MARK: Saving the popover's choices

    @Test func savingTakesTheCurrentChoicesAndNoGoal() {
        let setup = FocusSetup.saving(minutes: 60, selectedIDs: ["social", "deleted", "video"], mode: .allow,
                                      strict: true, categories: Self.categories)
        #expect(setup.minutes == 60)
        #expect(setup.categoryIDs == ["social", "video"])
        #expect(setup.mode == .allow)
        #expect(setup.strict)
        #expect(setup.goal == nil)
        #expect(setup.name == FocusSetup.defaultName)
    }

    // MARK: Storage

    @Test func aSetupSurvivesAJSONRoundTrip() throws {
        let setups = [
            Self.setup(["xcode"], mode: .allow, minutes: 90, strict: true),
            Self.setup(["social", "video"], minutes: 0, goal: "Draft the intro"),
            FocusSetup(),
        ]
        let data = try JSONEncoder().encode(setups)
        #expect(try JSONDecoder().decode([FocusSetup].self, from: data) == setups)
    }

    @Test func aFieldThatIsMissingOrUnreadableTakesItsDefault() throws {
        // One that fails to decode would make the whole list read as empty.
        let id = UUID()
        let json = Data(#"{"id":"\#(id.uuidString)","name":"Old","mode":"something-new","minutes":"soon"}"#.utf8)
        let setup = try JSONDecoder().decode(FocusSetup.self, from: json)
        #expect(setup == FocusSetup(id: id, name: "Old"))
    }

    @Test func aSetupNeedsItsIdAndName() {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(FocusSetup.self, from: Data(#"{"name":"x"}"#.utf8)) }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(FocusSetup.self, from: Data(#"{"id":"\#(UUID().uuidString)"}"#.utf8))
        }
    }

    // MARK: Order

    @Test func movingASetupStopsAtEitherEnd() {
        let a = FocusSetup(name: "A"), b = FocusSetup(name: "B"), c = FocusSetup(name: "C")
        let list = [a, b, c]
        #expect(FocusSetup.moving(b.id, by: -1, in: list).map(\.name) == ["B", "A", "C"])
        #expect(FocusSetup.moving(b.id, by: 1, in: list).map(\.name) == ["A", "C", "B"])
        #expect(FocusSetup.moving(a.id, by: -1, in: list) == list)
        #expect(FocusSetup.moving(c.id, by: 1, in: list) == list)
        #expect(FocusSetup.moving(UUID(), by: 1, in: list) == list)
        #expect(FocusSetup.moving(a.id, by: 5, in: list).map(\.name) == ["B", "C", "A"], "clamped to the end")
    }

    // MARK: Symbols

    @Test func everyCuratedSymbolExistsAndIsOnlyListedOnce() {
        #expect(FocusSetup.symbols.count == 12)
        #expect(Set(FocusSetup.symbols.map(\.symbol)).count == FocusSetup.symbols.count)
        for choice in FocusSetup.symbols {
            #expect(NSImage(systemSymbolName: choice.symbol, accessibilityDescription: nil) != nil,
                    "\(choice.symbol) is not an SF Symbol")
            #expect(!choice.name.isEmpty)
        }
        #expect(FocusSetup.symbols.map(\.symbol).contains(FocusSetup.defaultSymbol))
    }
}

// MARK: - The bar and the menu

struct FocusSetupsBarTests {
    static func list(_ count: Int) -> [FocusSetup] {
        (0..<count).map { FocusSetup(name: "Setup \($0 + 1)") }
    }

    @Test(arguments: [0, 1, 3, 4])
    func upToFourSitInTheRow(_ count: Int) {
        let split = FocusSetupsBar.split(Self.list(count))
        #expect(split.inline.count == count)
        #expect(split.overflow.isEmpty)
    }

    @Test(arguments: [5, 6, 9])
    func pastFourThreeStayAndTheRestGoUnderMore(_ count: Int) {
        let list = Self.list(count)
        let split = FocusSetupsBar.split(list)
        #expect(split.inline == Array(list.prefix(3)))
        #expect(split.overflow == Array(list.dropFirst(3)))
    }
}

@MainActor
struct FocusSetupsMenuTests {
    typealias T = FocusSetupTests

    final class Target: NSObject {
        @objc func start(_ sender: NSMenuItem) {}
    }

    static func items(_ setups: [FocusSetup], target: Target = Target()) -> [NSMenuItem] {
        FocusSetupsMenu.items(for: setups, categories: T.categories, target: target, action: #selector(Target.start(_:)))
    }

    @Test func noSetupsAddNothingToTheMenu() {
        #expect(Self.items([]).isEmpty)
    }

    @Test func eachSetupIsAnItemWithItsSummaryAndSymbol() throws {
        let setups = [
            FocusSetup(name: "Deep work", symbol: "brain.head.profile", minutes: 90, categoryIDs: ["xcode"], mode: .allow, strict: true),
            FocusSetup(name: "Writing", symbol: "pencil", minutes: 45, categoryIDs: ["social", "video"]),
        ]
        let target = Target()
        let items = Self.items(setups, target: target)
        #expect(items.map(\.title) == ["Deep work", "Writing"])
        #expect(items.map(\.subtitle) == ["1 hr 30 min · Only Xcode · strict", "45 min · Social, Video"])
        #expect(items.allSatisfy { $0.image != nil && $0.target === target && $0.action != nil })
        #expect(items.compactMap { $0.representedObject as? String } == setups.map { $0.id.uuidString })
    }

    @Test func fourStayInTheMenuAndFiveGoUnderOneItem() throws {
        #expect(Self.items(FocusSetupsBarTests.list(4)).count == 4)

        let items = Self.items(FocusSetupsBarTests.list(5))
        #expect(items.count == 1)
        #expect(items[0].title == "Start a setup")
        let submenu = try #require(items[0].submenu)
        #expect(submenu.items.map(\.title) == (1...5).map { "Setup \($0)" })
    }

    @Test func aSetupThatCannotStartHasNoActionSoTheMenuDimsIt() throws {
        let broken = FocusSetup(name: "Old", categoryIDs: ["deleted"])
        let items = Self.items([broken, FocusSetup(name: "Fine", categoryIDs: ["social"])])
        #expect(items[0].action == nil, "isEnabled alone is undone by the menu's auto-enabling")
        #expect(items[0].subtitle == "Its categories are gone")
        #expect(items[1].action != nil)
    }
}
