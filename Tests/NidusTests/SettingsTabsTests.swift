//
//  SettingsTabsTests.swift
//  NidusTests
//
//  Where each page of Settings opens: the tab it belongs to, and whether it is
//  pushed on that tab's own page. Pages are named as the app names them, with
//  the same constants, so a renamed prefix fails here. The window itself is
//  not built: it would open on the screen.
//

import AppKit
import Foundation
import Testing
@testable import Nidus

@MainActor
struct SettingsRouteTests {
    static let allTabs = Set(SettingsTab.allCases)

    // MARK: The table

    @Test(arguments: [
        // A tab's own page is the tab, with nothing pushed.
        ("general", SettingsTab.general, false),
        ("blocking", .blocking, false),
        ("setups", .setups, false),
        ("schedules", .schedules, false),
        ("stats", .stats, false),
        ("about", .about, false),
        // Pages inside the others.
        (NidusModel.launchAppsPageID, .general, true),
        (NidusModel.categoryPagePrefix + "5C1D", .blocking, true),
        (NidusModel.setupPagePrefix + "0F6A3C1E-3B6E-4C57-A2A1-6E0A6B1F4D2B", .setups, true),
        (NidusModel.schedulePagePrefix + "sample-deep-work", .schedules, true),
        // Anything else is General, as itself.
        ("", .general, false),
        ("nowhere", .general, false),
        ("launch-apps-too", .general, false),
    ])
    func eachPageOpensInItsTab(page: String, tab: SettingsTab, pushes: Bool) {
        #expect(SettingsRoute.resolve(page) == SettingsRoute(tab: tab, pushes: pushes))
    }

    @Test func theListAndOneItemInItAreDifferentPages() {
        // The old check was a bare prefix, which matched both.
        #expect(SettingsRoute.resolve(NidusModel.setupsPageID) == SettingsRoute(tab: .setups, pushes: false))
        #expect(SettingsRoute.resolve(NidusModel.setupPagePrefix + "x") == SettingsRoute(tab: .setups, pushes: true))
        #expect(SettingsRoute.resolve("schedules") == SettingsRoute(tab: .schedules, pushes: false))
        #expect(SettingsRoute.resolve(NidusModel.schedulePagePrefix + "x") == SettingsRoute(tab: .schedules, pushes: true))
    }

    @Test func aPrefixAloneIsStillThatKindOfPage() {
        // The page itself says it is gone; the tab is right regardless.
        #expect(SettingsRoute.resolve(NidusModel.categoryPagePrefix) == SettingsRoute(tab: .blocking, pushes: true))
    }

    @Test(arguments: SettingsTab.allCases)
    func everyTabOpensAtItsOwnPage(_ tab: SettingsTab) {
        #expect(SettingsRoute.resolve(tab.pageID) == SettingsRoute(tab: tab, pushes: false))
    }

    @Test func theIdsThePagesAreOpenedWithAreTheOnesRouted() {
        // What the app's own entry points ask for.
        #expect(SettingsRoute.resolve(NidusModel.setupsPageID).tab == .setups)
        #expect(SettingsTab.setups.pageID == NidusModel.setupsPageID)
        #expect(SettingsTab.stats.pageID == "stats", "openStats asks for the tab by its old id")
        #expect(SettingsTab.schedules.pageID == "schedules")
    }

    // MARK: A tab that isn't there

    @Test func aPageForAMissingTabOpensGeneral() {
        let withoutSchedules = Self.allTabs.subtracting([.schedules])
        #expect(SettingsRoute.resolve("schedules", available: withoutSchedules) == SettingsRoute(tab: .general, pushes: false))
        // Pushed on General it would only say the page is gone.
        #expect(SettingsRoute.resolve(NidusModel.schedulePagePrefix + "x", available: withoutSchedules)
                == SettingsRoute(tab: .general, pushes: false))
    }

    @Test func theOtherTabsAreUnaffectedByAMissingOne() {
        let withoutSchedules = Self.allTabs.subtracting([.schedules])
        #expect(SettingsRoute.resolve("stats", available: withoutSchedules) == SettingsRoute(tab: .stats, pushes: false))
        #expect(SettingsRoute.resolve(NidusModel.setupPagePrefix + "x", available: withoutSchedules)
                == SettingsRoute(tab: .setups, pushes: true))
        #expect(SettingsRoute.resolve(NidusModel.categoryPagePrefix + "x", available: withoutSchedules)
                == SettingsRoute(tab: .blocking, pushes: true))
    }

    @Test func withOnlyGeneralEverythingOpensThere() {
        for page in ["stats", "setups", "about", NidusModel.categoryPagePrefix + "x", "nowhere"] {
            #expect(SettingsRoute.resolve(page, available: [.general]) == SettingsRoute(tab: .general, pushes: false), "\(page)")
        }
    }
}

@MainActor
struct SettingsTabTests {
    @Test func theTabsAreInTheOrderOfTheToolbar() {
        #expect(SettingsTab.allCases == [.general, .blocking, .setups, .schedules, .stats, .about])
    }

    @Test func eachTabHasAnItsOwnNameAndASymbolThatExists() {
        let titles = SettingsTab.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        for tab in SettingsTab.allCases {
            #expect(!tab.title.isEmpty)
            #expect(NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil) != nil, "\(tab.symbol) is not an SF Symbol")
        }
    }

    @Test func theWindowReopensOnTheTabItWasLeftOn() {
        let all = SettingsTab.allCases
        #expect(SettingsTab.restored(from: "stats", available: all) == .stats)
        #expect(SettingsTab.restored(from: "about", available: all) == .about)
    }

    @Test func nothingSavedOrNothingLikeATabOpensGeneral() {
        let all = SettingsTab.allCases
        #expect(SettingsTab.restored(from: "", available: all) == .general)
        #expect(SettingsTab.restored(from: "Stats", available: all) == .general, "ids are lower case")
        #expect(SettingsTab.restored(from: "nowhere", available: all) == .general)
    }

    @Test func aSavedTabThatIsGoneOpensGeneral() {
        let withoutSchedules = SettingsTab.available { $0 != .schedules }
        #expect(SettingsTab.restored(from: "schedules", available: withoutSchedules) == .general)
        #expect(SettingsTab.restored(from: "setups", available: withoutSchedules) == .setups)
    }

    // MARK: The pages behind them

    @Test func everyTabHasAPage() {
        let model = NidusModel()
        for tab in SettingsTab.allCases {
            #expect(model.settingsRoot(for: tab) != nil, "\(tab.title) has no page")
        }
    }

    @Test func aTabWithNoPageIsLeftOutAndTheOthersKeepTheirOrder() {
        // How Schedules stayed out until its page existed, and came in with
        // no other change.
        let without = SettingsTab.available { $0 != .schedules }
        #expect(without == [.general, .blocking, .setups, .stats, .about])
        #expect(SettingsTab.available { _ in true } == SettingsTab.allCases)
    }

    @Test func theWindowHasEveryTabNow() {
        let controller = SettingsWindowController()
        #expect(controller.tabs.isEmpty, "no model, no tabs")
        let model = NidusModel()
        controller.model = model
        #expect(controller.tabs == SettingsTab.allCases)
    }

    @Test func aPushedPageIsServedByTheModel() {
        let model = NidusModel()
        let category = FocusCategory.presets[0]
        #expect(model.makeSettingsPage(id: NidusModel.categoryPagePrefix + category.id) != nil)
        #expect(model.makeSettingsPage(id: NidusModel.launchAppsPageID) != nil)
        #expect(model.makeSettingsPage(id: NidusModel.categoryPagePrefix + "deleted") == nil)
        #expect(model.makeSettingsPage(id: "nowhere") == nil)
    }
}

@MainActor
struct SettingsStacksTests {
    @Test func eachTabKeepsItsOwnStack() {
        let settings = SettingsWindowController()
        #expect(settings.router(for: .blocking) === settings.router(for: .blocking))
        #expect(settings.router(for: .blocking) !== settings.router(for: .setups))
    }

    @Test func backPopsTheTabShowing() {
        let settings = SettingsWindowController()
        // No window yet: General is the one showing.
        #expect(settings.selectedTab == .general)
        settings.router(for: .general).open(NidusModel.launchAppsPageID, title: "Apps to open")
        settings.router(for: .blocking).open(NidusModel.categoryPagePrefix + "x", title: "X")
        settings.goBack()
        #expect(settings.router(for: .general).path.isEmpty)
        #expect(settings.router(for: .blocking).path.count == 1, "another tab's stack is left alone")
    }

    @Test func backOnATabsOwnPageDoesNothing() {
        let settings = SettingsWindowController()
        settings.goBack()
        #expect(settings.router(for: .general).path.isEmpty)
    }

    @Test func resettingAStackToAPageOrToItsRoot() {
        // What opening a page does to the tab's stack.
        let router = SettingsRouter()
        let pushed = SettingsRoute.resolve(NidusModel.categoryPagePrefix + "x")
        router.reset(to: pushed.pushes ? NidusModel.categoryPagePrefix + "x" : nil, title: "X")
        #expect(router.path.map(\.id) == [NidusModel.categoryPagePrefix + "x"])
        let root = SettingsRoute.resolve("blocking")
        router.reset(to: root.pushes ? "blocking" : nil, title: "Blocking")
        #expect(router.path.isEmpty)
    }
}

@MainActor
struct AboutPageTests {
    @Test func theVersionReadsAsAVersion() {
        #expect(FocusAboutPage.versionLine("0.1.3") == "Version 0.1.3")
        #expect(FocusAboutPage.versionLine(" 1.0 \n") == "Version 1.0")
    }

    @Test func noVersionMeansNoLine() {
        #expect(FocusAboutPage.versionLine(nil) == nil)
        #expect(FocusAboutPage.versionLine("") == nil)
        #expect(FocusAboutPage.versionLine("  ") == nil)
    }

    @Test func theWordsHaveNoWebAddress() {
        for words in [FocusAboutPage.tagline, FocusAboutPage.privacy, FocusAboutPage.credits] {
            #expect(!words.lowercased().contains("http"))
            #expect(!words.contains("www."))
        }
        #expect(FocusAboutPage.privacy.contains("never connects to the internet"))
        #expect(FocusAboutPage.credits.contains("MIT"))
    }
}
