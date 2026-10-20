//
//  SettingsJumpTests.swift
//  NidusTests
//
//  "Jump to" in Settings: what the index finds for the words people use, that
//  every entry opens a page Settings has, in the tab its place names, and the
//  keyboard model (choose, open, clear). The window and the field are not
//  built; the index is plain data and the state is a small object.
//

import Foundation
import Testing
@testable import Nidus

@MainActor
struct SettingsJumpIndexTests {
    private func top(_ query: String) -> SettingsJumpEntry? { SettingsJumpIndex.results(for: query).first }
    private func ids(_ query: String) -> [String] { SettingsJumpIndex.results(for: query).map(\.id) }

    // MARK: The index itself

    @Test func everyEntryHasAUniqueIDAndAName() {
        let all = SettingsJumpIndex.entries
        #expect(Set(all.map(\.id)).count == all.count)
        for entry in all {
            #expect(!entry.title.isEmpty, "\(entry.id)")
            #expect(!entry.keywords.isEmpty || !entry.title.isEmpty)
        }
    }

    @Test func everyEntryOpensAPageSettingsHasInTheTabItNames() {
        let model = NidusModel()
        for entry in SettingsJumpIndex.entries {
            let route = SettingsRoute.resolve(entry.page)
            #expect(entry.tab == route.tab)
            #expect(entry.place.hasPrefix(route.tab.title), "\(entry.id): \(entry.place)")
            // The page exists: a tab's own page, or the page pushed in it.
            if route.pushes {
                #expect(model.makeSettingsPage(id: entry.page) != nil, "\(entry.id) opens \(entry.page), which is gone")
            } else {
                #expect(SettingsTab(rawValue: entry.page) == route.tab, "\(entry.id) opens \(entry.page), which is not a tab")
                #expect(model.settingsRoot(for: route.tab) != nil, "\(entry.id)")
            }
        }
    }

    @Test func everyTabCanBeJumpedTo() {
        for tab in SettingsTab.allCases {
            #expect(SettingsJumpIndex.entries.contains { $0.page == tab.pageID }, "\(tab.title) has no entry")
        }
        #expect(SettingsJumpIndex.entries.contains { $0.page == NidusModel.inboxPageID })
        #expect(SettingsJumpIndex.entries.contains { $0.page == NidusModel.launchAppsPageID })
    }

    @Test func aPushedPageKeepsItsOwnTitleForBack() {
        let capture = SettingsJumpIndex.entries.first { $0.id == "capture-shortcut" }
        #expect(capture?.page == NidusModel.inboxPageID)
        #expect(capture?.pageTitle == "Inbox", "Back reads the page, not the setting")
    }

    // MARK: The words people use

    @Test func breakFindsTheBreakSettingsInGeneral() {
        #expect(top("break")?.tab == .general)
        #expect(ids("break").prefix(2).contains("break"))
        #expect(ids("break").contains("break-rules"))
    }

    @Test func strictFindsStrictMode() {
        #expect(top("strict")?.id == "strict")
        #expect(top("Strict")?.tab == .general)
        #expect(SettingsJumpIndex.results(for: "stricter").isEmpty, "a longer word is not the same word")
    }

    @Test func calendarFindsTheSchedulesCalendarCheck() {
        #expect(top("calendar")?.id == "calendar")
        #expect(top("calendar")?.tab == .schedules)
        #expect(top("meetings")?.tab == .schedules)
    }

    @Test func inboxFindsTheInboxPage() {
        #expect(top("inbox")?.page == NidusModel.inboxPageID)
        #expect(SettingsRoute.resolve(top("inbox")!.page) == SettingsRoute(tab: .general, pushes: true))
    }

    @Test func plaqueFindsPlaqueInGeneral() {
        #expect(top("Plaque")?.id == "plaque")
        #expect(top("plaque")?.tab == .general)
        #expect(top("e-ink")?.id == "plaque")
    }

    @Test func exceptionsFindsWebsiteExceptionsInBlocking() {
        #expect(top("exceptions")?.id == "exceptions")
        #expect(top("exception")?.id == "exceptions", "singular or plural")
        #expect(top("exceptions")?.tab == .blocking)
    }

    @Test func activityFindsTheActivityTab() {
        #expect(top("activity")?.id == "activity")
        #expect(SettingsRoute.resolve(top("activity")!.page) == SettingsRoute(tab: .activity, pushes: false))
    }

    @Test func shortcutFindsBothShortcutsAndOpenNidusFirst() {
        let found = ids("shortcut")
        #expect(found.prefix(2) == ["open-shortcut", "capture-shortcut"])
        #expect(found.contains("focus-shortcuts"), "Apple's Shortcuts too, a little lower")
        #expect(ids("shortcuts") == found, "plural or not")
        #expect(top("hotkey")?.id == "open-shortcut")
    }

    @Test func eachTabIsFoundByName() {
        for tab in SettingsTab.allCases {
            let first = top(tab.title)
            #expect(first?.page == tab.pageID, "\(tab.title) -> \(first?.id ?? "nothing")")
        }
    }

    @Test func moreWordsNarrowTheResults() {
        #expect(ids("capture shortcut").first == "capture-shortcut")
        #expect(ids("open nidus").first == "open-shortcut")
        #expect(!ids("capture shortcut").contains("plaque"))
        #expect(ids("break shortcut").isEmpty, "every word must be found")
    }

    @Test func caseAccentsAndSpacesDoNotMatter() {
        #expect(ids("  BREAK ") == ids("break"))
        #expect(ids("Pl\u{00E2}que") == ids("plaque"))
    }

    @Test func nothingIsFoundForNothingOrNonsense() {
        #expect(SettingsJumpIndex.results(for: "").isEmpty)
        #expect(SettingsJumpIndex.results(for: "   ").isEmpty)
        #expect(SettingsJumpIndex.results(for: "---").isEmpty)
        #expect(SettingsJumpIndex.results(for: "zzzzqq").isEmpty)
    }

    @Test func theListIsShortAndBestFirst() {
        let all = SettingsJumpIndex.results(for: "s")
        #expect(all.count <= SettingsJumpIndex.maxResults)
        #expect(SettingsJumpIndex.results(for: "s", limit: 2).count == 2)
        #expect(SettingsJumpIndex.results(for: "s", limit: 0).isEmpty)
        // A word of the name beats a word only in the keywords.
        #expect(ids("snooze").first == "snooze")
        #expect(ids("pause").contains("strict"), "found by a keyword too")
    }

    @Test func aPluralDropsItsSOnlyWhenLongEnough() {
        #expect(SettingsJumpIndex.words("Exceptions") == ["exception"])
        #expect(SettingsJumpIndex.words("Stats Mac's") == ["stat", "mac", "s"])
        #expect(SettingsJumpIndex.words("class bus") == ["class", "bus"])
    }
}

@MainActor
struct SettingsJumpStateTests {
    private final class Opened {
        var calls: [(page: String, title: String)] = []
    }

    private func make() -> (SettingsJump, Opened) {
        let opened = Opened()
        return (SettingsJump { page, title in opened.calls.append((page, title)) }, opened)
    }

    @Test func noQueryMeansNoSearch() {
        let (jump, _) = make()
        #expect(!jump.isSearching)
        jump.query = "   "
        #expect(!jump.isSearching, "spaces are not a search")
        jump.query = "break"
        #expect(jump.isSearching)
    }

    @Test func theArrowKeysChooseAndStopAtTheEnds() {
        let (jump, _) = make()
        jump.query = "shortcut"
        let count = jump.results.count
        #expect(count >= 2)
        #expect(jump.selection == 0)
        jump.move(-1)
        #expect(jump.selection == 0, "up from the first stays")
        jump.move(1)
        #expect(jump.selection == 1)
        for _ in 0..<(count + 3) { jump.move(1) }
        #expect(jump.selection == count - 1, "down from the last stays")
    }

    @Test func movingWithNoResultsDoesNothing() {
        let (jump, _) = make()
        jump.move(1)
        #expect(jump.selection == 0)
        jump.query = "zzzzqq"
        jump.move(1)
        #expect(jump.selection == 0)
    }

    @Test func aNewQueryStartsAtTheTop() {
        let (jump, _) = make()
        jump.query = "shortcut"
        jump.move(1)
        #expect(jump.selection == 1)
        jump.query = "shortcuts"
        #expect(jump.selection == 0)
    }

    @Test func returnOpensTheChosenRowAndClearsTheField() {
        let (jump, opened) = make()
        jump.query = "shortcut"
        jump.move(1)
        let chosen = jump.results[1]
        jump.openSelected()
        #expect(opened.calls.count == 1)
        #expect(opened.calls.first?.page == chosen.page)
        #expect(opened.calls.first?.title == chosen.pageTitle)
        #expect(jump.query.isEmpty)
        #expect(!jump.isSearching)
    }

    @Test func returnWithNothingFoundOpensNothing() {
        let (jump, opened) = make()
        jump.openSelected()
        jump.query = "zzzzqq"
        jump.openSelected()
        #expect(opened.calls.isEmpty)
        #expect(jump.query == "zzzzqq", "the words stay so they can be fixed")
    }

    @Test func clickingARowOpensThatRow() {
        let (jump, opened) = make()
        jump.query = "calendar"
        jump.open(jump.results[0])
        #expect(opened.calls.map(\.page) == [SettingsTab.schedules.pageID])
        #expect(jump.query.isEmpty)
    }

    @Test func escapeClears() {
        let (jump, opened) = make()
        jump.query = "break"
        jump.move(1)
        jump.clear()
        #expect(jump.query.isEmpty)
        #expect(jump.selection == 0)
        #expect(opened.calls.isEmpty)
    }

    @Test func commandFAsksForFocusEachTime() {
        let (jump, _) = make()
        let before = jump.focusRequest
        jump.requestFocus()
        jump.requestFocus()
        #expect(jump.focusRequest == before + 2)
    }

    @Test func theModelOpensThroughSettingsNavigationAndIsSafeWithoutAHost() {
        // No host, so nothing opens; the closure the model gave is the
        // workspace's, and a missing host is a no-op rather than a crash.
        let model = NidusModel()
        model.settingsJump.query = "inbox"
        model.settingsJump.openSelected()
        #expect(model.settingsJump.query.isEmpty)
    }
}
