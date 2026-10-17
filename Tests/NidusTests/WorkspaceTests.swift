//
//  WorkspaceTests.swift
//  NidusTests
//
//  Saved workspaces: a 0.3 setup still reads, and a field written wrongly
//  loses only itself; inherit, none and a value for apps and Shortcuts; what
//  the setup asks a session to start with; a running session keeps what it
//  started with; documents and pages open exactly once per start and never on
//  a restore or after a break; a file that can't be found is reported while
//  the rest opens; addresses are http or https only; a page the setup's own
//  rules block is found, and the one fix is exact; and nothing here reaches
//  for a shell.
//
//  Nothing is really opened: the Mac's side is a fake that counts calls,
//  bookmarks are fake data, files live in a temporary folder.
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Nidus

// MARK: - Fakes

/// Records what a start asked the Mac to do.
@MainActor
final class FakeOpener: WorkspaceOpening {
    var apps: [[String]] = []
    var appActivations: [Bool] = []
    var opened: [URL] = []
    var shortcuts: [String] = []
    /// Addresses (or paths) the Mac declines to open.
    var refuses: Set<String> = []

    func openApplications(_ bundleIDs: [String], activating: Bool) {
        apps.append(bundleIDs)
        appActivations.append(activating)
    }

    func open(_ url: URL) -> Bool {
        guard !refuses.contains(url.absoluteString), !refuses.contains(url.path) else { return false }
        opened.append(url)
        return true
    }

    func runShortcut(_ name: String) async {
        shortcuts.append(name)
    }
}

/// Bookmarks that are just the path, so a test says where one now points.
struct FakeBookmarks: BookmarkResolving {
    /// Original path -> where it points now, and whether it is stale.
    var redirects: [String: (url: URL, isStale: Bool)] = [:]
    /// Bookmarks that resolve to nothing.
    var unresolvable: Set<Data> = []

    func bookmark(for url: URL) -> Data? { Data(url.path.utf8) }

    func resolve(_ bookmark: Data) -> (url: URL, isStale: Bool)? {
        if unresolvable.contains(bookmark) { return nil }
        let path = String(decoding: bookmark, as: UTF8.self)
        if let moved = redirects[path] { return moved }
        return (URL(fileURLWithPath: path), false)
    }
}

/// A folder of real files to point bookmarks at, removed afterwards.
final class Workspace {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func file(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        return url
    }

    @discardableResult
    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private func page(_ text: String) throws -> WorkspaceResource {
    try WorkspaceResource.webPage(from: text).get()
}

/// A plan the way a setup's start commits it, for the controller to run.
private func workspacePlan(resources: [WorkspaceResource] = [], apps: [String] = [], start: String? = nil,
                  websites: [String] = [], mode: SessionPlan.Mode = .block) -> SessionPlan {
    var plan = SessionPlan(goal: "Grant", duration: 25 * 60, mode: mode, apps: [], websites: websites)
    plan.launchApps = apps
    plan.startShortcut = start
    plan.resources = resources
    plan.setupID = UUID()
    return plan
}

// MARK: - A setup written by 0.3, and by 0.4 wrongly

struct WorkspaceStorageTests {
    /// What 0.3 saved: none of the new keys.
    static let legacy = #"""
    {"id":"6D0C0F4E-2E35-4C2B-9C8E-0A1B2C3D4E5F","name":"Writing","symbol":"pencil","minutes":45,
     "categoryIDs":["social","video"],"mode":"block","strict":true,"goal":"Draft the intro"}
    """#

    @Test func aZeroPointThreeSetupInheritsEverything() throws {
        let setup = try JSONDecoder().decode(FocusSetup.self, from: Data(Self.legacy.utf8))
        #expect(setup.name == "Writing" && setup.minutes == 45 && setup.strict && setup.goal == "Draft the intro")
        #expect(setup.launchApps == nil, "missing is inherit, not none")
        #expect(setup.startShortcut == nil && setup.endShortcut == nil)
        #expect(setup.websiteExceptions.isEmpty && setup.resources.isEmpty)
        #expect(!setup.hasWorkspace)
        let request = setup.request(categories: FocusSetupTests.categories)
        #expect(request.launchApps == nil && request.startShortcut == nil && request.endShortcut == nil)
        #expect(request.resources.isEmpty && request.websiteExceptions.isEmpty)
    }

    @Test func aWholeListOfZeroPointThreeSetupsStillReads() throws {
        let list = "[\(Self.legacy),\(Self.legacy.replacingOccurrences(of: "6D0C0F4E", with: "7D0C0F4E"))]"
        let setups = try #require(LossyJSON.list(FocusSetup.self, from: Data(list.utf8)))
        #expect(setups.count == 2)
    }

    @Test func aFieldWrittenWrongLosesOnlyItself() throws {
        let id = UUID().uuidString
        let json = #"""
        {"id":"\#(id)","name":"Odd","minutes":30,
         "launchApps":"not a list","startShortcut":5,"endShortcut":["x"],
         "websiteExceptions":[{"kind":"nope","address":"a.com"},{"kind":"exact","address":"a.com/p"},7],
         "resources":[{"id":"not-a-uuid","kind":"document"},
                      {"id":"\#(UUID().uuidString)","kind":"webPage","displayName":"a.com","url":"https://a.com"}]}
        """#
        let setup = try JSONDecoder().decode(FocusSetup.self, from: Data(json.utf8))
        #expect(setup.name == "Odd" && setup.minutes == 30, "the rest of the setup is unharmed")
        #expect(setup.launchApps == nil, "a bad list is inherit")
        #expect(setup.startShortcut == nil && setup.endShortcut == nil)
        #expect(setup.websiteExceptions == [WebsiteException(kind: .exact, address: "a.com/p")])
        #expect(setup.resources.count == 1 && setup.resources[0].kind == .webPage)
    }

    @Test func oneBadAppDropsOnlyThatApp() throws {
        let json = #"""
        {"id":"\#(UUID().uuidString)","name":"Apps","launchApps":[{"bundleID":"a.b","name":"A"},42,{"bundleID":7}]}
        """#
        let setup = try JSONDecoder().decode(FocusSetup.self, from: Data(json.utf8))
        #expect(setup.launchApps == [BlockedApp(bundleID: "a.b", name: "A")])
    }

    @Test func aSetupWithAWorkspaceSurvivesARoundTrip() throws {
        let doc = WorkspaceResource(kind: .document, displayName: "Aims.docx", bookmark: Data([1, 2, 3]), path: "/tmp/Aims.docx")
        let setup = FocusSetup(name: "Grant writing", categoryIDs: ["video"],
                               launchApps: [BlockedApp(bundleID: "com.microsoft.Word", name: "Word")],
                               startShortcut: "Work on", endShortcut: "",
                               websiteExceptions: [WebsiteException(kind: .exact, address: "youtube.com/watch?v=abc")],
                               resources: [doc, try page("example.org/guide")])
        let back = try JSONDecoder().decode(FocusSetup.self, from: JSONEncoder().encode(setup))
        #expect(back == setup)
        #expect(back.endShortcut == "", "none stays none, not inherit")
        let none = FocusSetup(name: "None", launchApps: [])
        #expect(try JSONDecoder().decode(FocusSetup.self, from: JSONEncoder().encode(none)).launchApps == [])
    }
}

// MARK: - Inherit, none, its own

struct WorkspaceRequestTests {
    typealias T = FocusSetupTests

    @Test func inheritNoneAndOwnForApps() {
        func apps(_ list: [BlockedApp]?) -> [String]? {
            FocusSetup(name: "A", categoryIDs: ["social"], launchApps: list).request(categories: T.categories).launchApps
        }
        #expect(apps(nil) == nil, "Settings' apps")
        #expect(apps([]) == [], "none, even if Settings has some")
        #expect(apps([BlockedApp(bundleID: "a", name: "A"), BlockedApp(bundleID: "b", name: "B")]) == ["a", "b"])
        #expect(apps([BlockedApp(bundleID: "a", name: "A"), BlockedApp(bundleID: "a", name: "A again")]) == ["a"],
                "an app twice opens once")
    }

    @Test func inheritNoneAndOwnForShortcuts() {
        func request(_ start: String?, _ end: String?) -> SessionRequest {
            FocusSetup(name: "S", categoryIDs: ["social"], startShortcut: start, endShortcut: end).request(categories: T.categories)
        }
        #expect(request(nil, nil).startShortcut == nil && request(nil, nil).endShortcut == nil)
        #expect(request("", "").startShortcut == "" && request("", "").endShortcut == "", "none")
        #expect(request("On", "Off").startShortcut == "On" && request("On", "Off").endShortcut == "Off")
        #expect(request("On", nil).endShortcut == nil, "each end chooses on its own")
    }

    @Test func exceptionsAreAddedNotSubstituted() {
        let ex = WebsiteException(kind: .exact, address: "youtube.com/watch?v=abc")
        let request = FocusSetup(name: "E", categoryIDs: ["video"], websiteExceptions: [ex]).request(categories: T.categories)
        #expect(request.websiteExceptions == [ex])
        #expect(FocusSetup(name: "E", categoryIDs: ["video"]).request(categories: T.categories).websiteExceptions.isEmpty)
    }

    @Test func theRequestCarriesTheSetupAndItsResources() throws {
        let doc = WorkspaceResource(kind: .document, displayName: "Aims.docx", path: "/tmp/Aims.docx")
        let setup = FocusSetup(name: "Grant", categoryIDs: ["video"], resources: [doc, try page("example.org/guide")])
        let request = setup.request(categories: T.categories, goalDraft: "Typed")
        #expect(request.setupID == setup.id)
        #expect(request.resources == setup.resources)
        #expect(request.goal == "Typed")
    }

    @Test func theSummaryCountsWhatItOpensAndOnlyThen() throws {
        #expect(T.setup(["social", "video"]).planSummary(categories: T.categories) == "45 min · Social, Video")
        var setup = T.setup(["social", "video"])
        setup.launchApps = [BlockedApp(bundleID: "a", name: "A")]
        #expect(setup.planSummary(categories: T.categories) == "45 min · Social, Video · opens 1 item")
        setup.resources = [try page("example.org/a"), try page("example.org/b")]
        #expect(setup.planSummary(categories: T.categories) == "45 min · Social, Video · opens 3 items")
        setup.launchApps = nil
        setup.resources = []
        #expect(setup.opensSummary == nil, "Settings' apps are not the setup's own")
    }

    @Test func theLineSummariesSayUsesSettingsUntilChanged() {
        var setup = FocusSetup(name: "L")
        #expect(setup.appsSummary == "Uses Settings" && setup.shortcutsSummary == "Uses Settings")
        #expect(setup.documentsSummary == "None" && setup.pagesSummary == "None" && setup.exceptionsSummary == "None added")
        setup.launchApps = []
        setup.startShortcut = ""
        setup.endShortcut = ""
        #expect(setup.appsSummary == "None" && setup.shortcutsSummary == "None")
        setup.launchApps = [BlockedApp(bundleID: "a", name: "Word"), BlockedApp(bundleID: "b", name: "Zotero"), BlockedApp(bundleID: "c", name: "Preview")]
        #expect(setup.appsSummary == "Word, Zotero and 1 more")
        setup.startShortcut = "Work on"
        setup.endShortcut = nil
        #expect(setup.shortcutsSummary == "On start: Work on, on end: Settings")
        setup.websiteExceptions = [WebsiteException(kind: .exact, address: "a.com/p")]
        #expect(setup.exceptionsSummary == "1 page")
    }

    private func defaults() -> StartDefaults {
        StartDefaults(mode: .block, selectedCategoryIDs: ["social"], categories: T.categories,
                      launchApps: ["settings.app"], startShortcut: "Settings on", endShortcut: "Settings off",
                      defaultBreakRules: BreakRules(websites: ["x.com"]), projectName: { _ in "R01 renewal" })
    }

    private func resolvedPlan(for setup: FocusSetup, defaults: StartDefaults) throws -> SessionPlan {
        try #require(setup.request(categories: T.categories).resolved(with: defaults, length: { (25, false) })?.plan)
    }

    /// The one resolution `startSession` and a sequence's blocks share turns a
    /// setup's request into the plan: everything the setup sets is in it.
    @Test func resolvingASetupsRequestCommitsEverythingItSetsToThePlan() throws {
        let ex = WebsiteException(kind: .exact, address: "youtube.com/watch?v=abc")
        let project = UUID()
        let doc = WorkspaceResource(kind: .document, displayName: "Aims.docx", path: "/tmp/Aims.docx")
        let own = FocusSetup(name: "Grant", categoryIDs: ["video"],
                             launchApps: [BlockedApp(bundleID: "com.microsoft.Word", name: "Word")],
                             startShortcut: "On", endShortcut: "Off", websiteExceptions: [ex], resources: [doc],
                             project: .project(project), breakMinutes: 10, breakRules: BreakRules(apps: ["a.b"]))
        let plan = try resolvedPlan(for: own, defaults: defaults())
        #expect(plan.setupID == own.id)
        #expect(plan.launchApps == ["com.microsoft.Word"] && plan.startShortcut == "On" && plan.endShortcut == "Off")
        #expect(plan.resources == [doc] && plan.websiteExceptions == [ex])
        #expect(plan.projectID == project && plan.projectName == "R01 renewal")
        #expect(plan.breakLength == 10 * 60 && plan.breakRules == BreakRules(apps: ["a.b"]))
        #expect(!plan.isContinuation)
    }

    @Test func aSetupThatInheritsTakesSettingsAndNoneIsNotInheriting() throws {
        let inherits = try resolvedPlan(for: FocusSetup(name: "I", categoryIDs: ["social"]), defaults: defaults())
        #expect(inherits.launchApps == ["settings.app"] && inherits.startShortcut == "Settings on" && inherits.endShortcut == "Settings off")
        #expect(inherits.breakLength == nil, "Settings' break")
        #expect(inherits.breakRules == BreakRules(websites: ["x.com"]), "Settings' default rules")
        #expect(inherits.projectID == nil)

        let none = try resolvedPlan(for: FocusSetup(name: "N", categoryIDs: ["social"], launchApps: [], startShortcut: "", endShortcut: "",
                                            breakMinutes: 0, breakRules: BreakRules()), defaults: defaults())
        #expect(none.launchApps.isEmpty, "no apps even though Settings has one")
        #expect(none.startShortcut == nil && none.endShortcut == nil, "no Shortcut even though Settings has one")
        #expect(none.breakLength == 0)
        #expect(none.breakRules == BreakRules(), "an unrestricted break even though Settings has rules")
    }

    @Test func exceptionsAreInTheBlockListsPlanOnly() throws {
        let own = WebsiteException(kind: .exact, address: "youtube.com/watch?v=abc")
        var categories = T.categories
        let video = try #require(categories.firstIndex { $0.id == "video" })
        let theirs = WebsiteException(kind: .subtree, address: "youtube.com/@labtalks")
        categories[video].websiteExceptions = [theirs]
        var d = defaults()
        d.categories = categories
        let setup = FocusSetup(name: "E", categoryIDs: ["video"], websiteExceptions: [own, theirs])
        let block = try #require(setup.request(categories: categories).resolved(with: d, length: { (25, false) })?.plan)
        #expect(block.websiteExceptions == [theirs, own], "the category's, then the setup's, each once")
        var allow = setup
        allow.mode = .allow
        let plan = try #require(allow.request(categories: categories).resolved(with: d, length: { (25, false) })?.plan)
        #expect(plan.websiteExceptions.isEmpty, "an allow list already says what is let through")
    }
}

// MARK: - The plan is the snapshot

@MainActor
struct WorkspaceSnapshotTests {
    @Test func editingTheSetupLaterChangesNothingAboutARunningSession() throws {
        let h = Harness()
        var setup = FocusSetup(name: "Grant", categoryIDs: ["video"],
                               launchApps: [BlockedApp(bundleID: "com.microsoft.Word", name: "Word")],
                               startShortcut: "On", endShortcut: "Off",
                               websiteExceptions: [WebsiteException(kind: .exact, address: "youtube.com/watch?v=abc")],
                               resources: [try page("example.org/guide")],
                               project: .project(UUID()), breakMinutes: 10, breakRules: BreakRules(websites: ["x.com"]))
        let defaults = StartDefaults(mode: .block, selectedCategoryIDs: [], categories: FocusSetupTests.categories,
                                     projectName: { _ in "R01 renewal" })
        let committed = try #require(setup.request(categories: FocusSetupTests.categories)
            .resolved(with: defaults, length: { (25, false) })?.plan)
        h.engine.start(committed)

        // Every field of the setup changes, and it is renamed.
        setup.launchApps = nil
        setup.startShortcut = ""
        setup.endShortcut = nil
        setup.websiteExceptions = []
        setup.resources = []
        setup.project = .noProject
        setup.breakMinutes = 0
        setup.breakRules = BreakRules()
        setup.name = "Renamed"

        let running = try #require(h.engine.session?.plan)
        #expect(running == committed)
        #expect(running.resources.count == 1 && running.launchApps == ["com.microsoft.Word"])
        #expect(running.websiteExceptions.count == 1 && running.startShortcut == "On" && running.endShortcut == "Off")
        #expect(running.projectName == "R01 renewal" && running.breakLength == 600 && running.breakRules?.websites == ["x.com"])

        // And a relaunch gives the same plan back.
        let (again, _) = h.relaunch()
        #expect(again.session?.plan == committed)
    }
}

// MARK: - Once per start

@MainActor
struct WorkspaceLaunchTests {
    /// A controller whose Mac is a fake. Its session files are in `dir`.
    static func controller(in dir: URL, bookmarks: FakeBookmarks = FakeBookmarks(),
                           now: @escaping () -> Date = Date.init) -> (FocusController, FakeOpener) {
        let controller = FocusController(directory: dir, now: now)
        let opener = FakeOpener()
        controller.opener = opener
        controller.launcher = WorkspaceLauncher(bookmarks: bookmarks)
        return (controller, opener)
    }

    static func resources(_ w: Workspace) throws -> [WorkspaceResource] {
        [WorkspaceResource.file(at: try w.file("Aims.docx"), bookmarks: FakeBookmarks()),
         WorkspaceResource.file(at: try w.folder("References"), bookmarks: FakeBookmarks()),
         try page("example.org/guide")]
    }

    @Test func aStartOpensItsWorkspaceExactlyOnce() throws {
        let w = try Workspace()
        let (controller, opener) = Self.controller(in: w.root.appendingPathComponent("state"))
        var reports: [(WorkspaceReport, SessionPlan)] = []
        controller.onWorkspaceOpened = { reports.append(($0, $1)) }
        controller.start()
        defer { controller.end(); controller.stop() }

        controller.start(workspacePlan(resources: try Self.resources(w), apps: ["com.microsoft.Word"], start: "Work on"))

        #expect(opener.opened.map(\.lastPathComponent) == ["Aims.docx", "References", "guide"])
        #expect(opener.opened.count == 3)
        #expect(opener.apps == [["com.microsoft.Word"]] && opener.appActivations == [true])
        #expect(reports.count == 1 && reports[0].0.opened == 3 && reports[0].0.isClean)
        // Ticks, pauses, snoozes and extensions are not starts.
        controller.pause()
        controller.resume()
        controller.extend(by: 300)
        #expect(opener.opened.count == 3 && reports.count == 1)
    }

    @Test func startingTwiceOpensTwiceBecauseThatIsTwoStarts() throws {
        let w = try Workspace()
        let (controller, opener) = Self.controller(in: w.root.appendingPathComponent("state"))
        controller.start()
        defer { controller.end(); controller.stop() }
        let p = workspacePlan(resources: try Self.resources(w))
        controller.start(p)
        controller.start(p)
        #expect(opener.opened.count == 6)
    }

    @Test func aPlanThatWasAContinuationStartsAsANewSessionWhenThePersonStartsIt() throws {
        // "Again" and the toggle start the last plan, which may be a session
        // that followed a break: the person asked, so it opens its documents.
        let w = try Workspace()
        let (controller, opener) = Self.controller(in: w.root.appendingPathComponent("state"))
        controller.start()
        defer { controller.end(); controller.stop() }
        var p = workspacePlan(resources: try Self.resources(w))
        p.isContinuation = true
        controller.start(p)
        #expect(opener.opened.count == 3)
        #expect(controller.engine.session?.plan.isContinuation == false)
    }

    @Test func aSessionThatContinuesAfterABreakOpensNoDocumentsButStillRunsAppsAndTheShortcut() async throws {
        let w = try Workspace()
        let clock = TestClock()
        let (controller, opener) = Self.controller(in: w.root.appendingPathComponent("state"), now: { clock.now })
        var reports = 0
        controller.onWorkspaceOpened = { _, _ in reports += 1 }
        controller.breakLength = 5 * minute
        controller.start()
        defer { controller.end(); controller.stop() }
        controller.start(workspacePlan(resources: try Self.resources(w), apps: ["com.microsoft.Word"], start: "Focus on"))
        #expect(opener.opened.count == 3)

        // It runs its full length, the break runs out, and the same session starts again.
        clock.advance(25 * minute)
        controller.engine.tick()
        #expect(controller.engine.isOnBreak)
        clock.advance(5 * minute)
        controller.engine.tick()
        #expect(controller.engine.session?.plan.isContinuation == true)

        #expect(opener.opened.count == 3, "documents, folders and pages opened once")
        #expect(reports == 1)
        #expect(opener.apps.count == 2, "apps open at every work start, how Apple Focus comes back on")
        await controller.settleShortcuts()
        #expect(opener.shortcuts == ["Focus on", "Focus on"])
    }

    @Test func skippingTheBreakOpensNoDocumentsEither() throws {
        let w = try Workspace()
        let clock = TestClock()
        let (controller, opener) = Self.controller(in: w.root.appendingPathComponent("state"), now: { clock.now })
        controller.breakLength = 5 * minute
        controller.start()
        defer { controller.end(); controller.stop() }
        controller.start(workspacePlan(resources: try Self.resources(w)))
        clock.advance(25 * minute)
        controller.engine.tick()
        controller.skipBreak()
        #expect(controller.engine.session != nil)
        #expect(opener.opened.count == 3)
    }

    @Test func theEngineMarksTheSessionItRestartsAfterABreakAsAContinuation() throws {
        let h = Harness()
        h.engine.breakLength = 5 * minute
        var first = plan(25)
        first.resources = [try page("example.org/guide")]
        h.engine.start(first)
        #expect(h.engine.session?.plan.isContinuation == false)

        // The break runs out and the same session starts again.
        h.clock.advance(25 * minute)
        h.engine.tick()
        #expect(h.engine.isOnBreak)
        h.clock.advance(5 * minute)
        h.engine.tick()
        #expect(h.engine.session?.plan.isContinuation == true)
        #expect(h.engine.session?.plan.resources == first.resources, "it is the same plan, flagged")
        #expect(h.events.all.filter { $0 == .started }.count == 2)

        // Skipping the break does the same.
        h.clock.advance(25 * minute)
        h.engine.tick()
        h.engine.skipBreak()
        #expect(h.engine.session?.plan.isContinuation == true)

        // Starting it again by hand is a start of its own.
        h.engine.start(try #require(h.engine.lastPlan))
        #expect(h.engine.session?.plan.isContinuation == false)
    }

    @Test func aRestoreEmitsNoStartAndOpensNothing() throws {
        let h = Harness()
        var first = plan(25)
        first.resources = [try page("example.org/guide")]
        h.engine.start(first)
        // Nidus relaunches mid-session.
        let (restored, events) = h.relaunch()
        #expect(restored.session != nil)
        #expect(events.all.isEmpty, "no .started for a session that was already running")
        // And a Mac that sleeps and wakes is not a start either.
        h.engine.systemWillSleep()
        h.clock.advance(60)
        h.engine.systemDidWake()
        #expect(h.events.all.filter { $0 == .started }.count == 1)
    }

    @Test func aRelaunchedControllerOpensNothing() throws {
        let w = try Workspace()
        let state = w.root.appendingPathComponent("state")
        let (first, firstOpener) = Self.controller(in: state)
        first.start()
        first.start(workspacePlan(resources: try Self.resources(w), apps: ["com.microsoft.Word"], start: "Focus on"))
        #expect(firstOpener.opened.count == 3)
        first.stop()

        let (second, secondOpener) = Self.controller(in: state)
        var reports = 0
        second.onWorkspaceOpened = { _, _ in reports += 1 }
        second.start()
        defer { second.end(); second.stop() }
        #expect(second.engine.session != nil, "the session was restored")
        #expect(secondOpener.opened.isEmpty && secondOpener.apps.isEmpty && secondOpener.shortcuts.isEmpty)
        #expect(reports == 0)
    }

    @Test func aSessionWithNoResourcesSaysNothing() throws {
        let w = try Workspace()
        let (controller, opener) = Self.controller(in: w.root.appendingPathComponent("state"))
        var reports = 0
        controller.onWorkspaceOpened = { _, _ in reports += 1 }
        controller.start()
        defer { controller.end(); controller.stop() }
        controller.start(workspacePlan(apps: ["com.microsoft.Word"]))
        #expect(opener.opened.isEmpty && reports == 0)
        #expect(opener.apps == [["com.microsoft.Word"]], "0.3's apps, as before")
    }

    @Test func quitAppsReopenInTheBackgroundThroughTheSameOpener() throws {
        let w = try Workspace()
        let (controller, opener) = Self.controller(in: w.root.appendingPathComponent("state"))
        controller.start()
        defer { controller.stop() }
        var p = workspacePlan()
        p.reopensQuitApps = true
        controller.start(p)
        controller.engine.recordQuit("com.tinyspeck.slackmacgap")
        controller.end()
        #expect(opener.apps.last == ["com.tinyspeck.slackmacgap"] && opener.appActivations.last == false)
    }
}

// MARK: - Missing and moved

@MainActor
struct WorkspaceMissingTests {
    @Test func aMissingFileIsReportedAndTheRestStillOpens() throws {
        let w = try Workspace()
        let aims = WorkspaceResource.file(at: try w.file("Aims.docx"), bookmarks: FakeBookmarks())
        let budget = WorkspaceResource.file(at: try w.file("Budget.xlsx"), bookmarks: FakeBookmarks())
        let refs = WorkspaceResource.file(at: try w.folder("References"), bookmarks: FakeBookmarks())
        try FileManager.default.removeItem(at: w.root.appendingPathComponent("Aims.docx"))
        let opener = FakeOpener()

        let report = WorkspaceLauncher(bookmarks: FakeBookmarks()).open([aims, budget, refs, try page("example.org/guide")], using: opener)

        #expect(opener.opened.map(\.lastPathComponent) == ["Budget.xlsx", "References", "guide"])
        #expect(report.total == 4 && report.opened == 3)
        #expect(report.problems == [.init(resourceID: aims.id, name: "Aims.docx", kind: .document, reason: .notFound)])
        #expect(report.headline == "Opened 3 of 4.")
        #expect(report.detail == "Aims.docx can\u{2019}t be found. Choose it again in the setup.")
    }

    @Test func theCardNamesTheSetupAndWhatIsMissing() {
        var report = WorkspaceReport(total: 3, opened: 2)
        report.problems = [.init(resourceID: UUID(), name: "Aims.docx", kind: .document, reason: .notFound)]
        #expect(NidusModel.workspaceCardTitle(setupName: "Grant writing", report: report, conflicts: []) == "Grant writing: opened 2 of 3")
        #expect(NidusModel.workspaceCardTitle(setupName: nil, report: report, conflicts: []) == "Opened 2 of 3")
        #expect(NidusModel.workspaceCardLines(report: report, conflicts: [])
                == ["Aims.docx can\u{2019}t be found. Choose it again in the setup."])
    }

    @Test func severalProblemsAreOneSentenceEach() {
        func report(_ reasons: [(String, WorkspaceProblemReason)]) -> WorkspaceReport {
            WorkspaceReport(total: 5, opened: 5 - reasons.count, problems: reasons.map {
                .init(resourceID: UUID(), name: $0.0, kind: .document, reason: $0.1)
            })
        }
        #expect(report([("A.docx", .notFound), ("B", .notFound)]).detail
                == "A.docx and B can\u{2019}t be found. Choose them again in the setup.")
        #expect(report([("A", .notFound), ("B", .notFound), ("C", .notFound), ("D", .notFound)]).detail
                == "A, B and 2 more can\u{2019}t be found. Choose them again in the setup.")
        #expect(report([("Old.docx", .inTrash)]).detail == "Old.docx is in the Trash. Choose it again in the setup.")
        #expect(report([("A", .notFound), ("page", .couldNotOpen)]).detail
                == "A can\u{2019}t be found. page didn\u{2019}t open. Choose it again in the setup.")
        #expect(WorkspaceReport(total: 2, opened: 2).detail.isEmpty)
    }

    @Test func aFileThatMovedIsFoundByItsBookmarkAndTheBookmarkIsMadeAgain() throws {
        let w = try Workspace()
        let old = try w.file("Old/Aims.docx")
        let resource = WorkspaceResource.file(at: old, bookmarks: FakeBookmarks())
        // It moved and was renamed; the bookmark follows it and says it is stale.
        let now = try w.file("New/Aims v2.docx")
        try FileManager.default.removeItem(at: old)
        let bookmarks = FakeBookmarks(redirects: [old.path: (now, true)])
        let opener = FakeOpener()

        let report = WorkspaceLauncher(bookmarks: bookmarks).open([resource], using: opener)

        #expect(opener.opened == [now] && report.isClean)
        let refreshed = try #require(report.refreshed.first)
        #expect(refreshed.id == resource.id, "the same entry in the setup")
        #expect(refreshed.path == now.path && refreshed.displayName == "Aims v2.docx")
        #expect(refreshed.bookmark == Data(now.path.utf8))
    }

    @Test func aMovedFileWhoseBookmarkIsNotStaleIsStillRememberedAtItsNewPlace() throws {
        let w = try Workspace()
        let old = try w.file("a/Aims.docx")
        let resource = WorkspaceResource.file(at: old, bookmarks: FakeBookmarks())
        let now = try w.file("b/Aims.docx")
        try FileManager.default.removeItem(at: old)
        let launcher = WorkspaceLauncher(bookmarks: FakeBookmarks(redirects: [old.path: (now, false)]))
        guard case .file(let url, let refreshed) = launcher.locate(resource) else { Issue.record("not found"); return }
        #expect(url == now && refreshed?.path == now.path)
    }

    @Test func aFileThatHasNotMovedIsNotRewritten() throws {
        let w = try Workspace()
        let resource = WorkspaceResource.file(at: try w.file("Aims.docx"), bookmarks: FakeBookmarks())
        guard case .file(_, let refreshed) = WorkspaceLauncher(bookmarks: FakeBookmarks()).locate(resource) else {
            Issue.record("not found"); return
        }
        #expect(refreshed == nil)
    }

    @Test func theSavedPathIsTheFallbackWhenTheBookmarkLeadsNowhere() throws {
        let w = try Workspace()
        let url = try w.file("Aims.docx")
        var resource = WorkspaceResource.file(at: url, bookmarks: FakeBookmarks())
        resource.bookmark = Data([9, 9])  // an old bookmark that resolves to nothing
        let launcher = WorkspaceLauncher(bookmarks: FakeBookmarks(unresolvable: [Data([9, 9])]))
        guard case .file(let found, let refreshed) = launcher.locate(resource) else { Issue.record("not found"); return }
        #expect(found.standardizedFileURL.path == url.standardizedFileURL.path)
        #expect(refreshed?.bookmark == Data(url.path.utf8), "and the bookmark is made again")
    }

    @Test func aFileWithNeitherBookmarkNorPathIsMissing() {
        let resource = WorkspaceResource(kind: .document, displayName: "Gone.docx")
        #expect(WorkspaceLauncher().locate(resource) == .unavailable(.notFound))
        #expect(resource.shownName == "Gone.docx")
        #expect(WorkspaceResource(kind: .document, displayName: " ", path: "/x/Aims.docx").shownName == "Aims.docx")
    }

    @Test func aFileInTheTrashCountsAsGone() throws {
        let w = try Workspace()
        let url = try w.file("Aims.docx")
        let resource = WorkspaceResource.file(at: url, bookmarks: FakeBookmarks())
        // Moving a file to the Trash doesn't break a bookmark: it follows it there.
        let trashed = try w.file(".Trash/Aims.docx")
        try FileManager.default.removeItem(at: url)
        let launcher = WorkspaceLauncher(bookmarks: FakeBookmarks(redirects: [url.path: (trashed, false)]))
        #expect(launcher.locate(resource) == .unavailable(.inTrash))
        let opener = FakeOpener()
        let report = launcher.open([resource], using: opener)
        #expect(opener.opened.isEmpty && report.detail == "Aims.docx is in the Trash. Choose it again in the setup.")
    }

    @Test func aPageTheMacWillNotOpenIsReportedNotCounted() throws {
        let opener = FakeOpener()
        let bad = try page("example.org/refused")
        opener.refuses = ["https://example.org/refused"]
        let report = WorkspaceLauncher().open([bad, try page("example.org/fine")], using: opener)
        #expect(report.opened == 1 && report.problems.first?.reason == .couldNotOpen)
        #expect(report.detail == "example.org/refused didn\u{2019}t open.")
    }

    @Test func aHandEditedAddressThatIsNotHttpIsNeverOpened() throws {
        let opener = FakeOpener()
        let tampered = [
            WorkspaceResource(kind: .webPage, displayName: "x", url: "file:///etc/passwd"),
            WorkspaceResource(kind: .webPage, displayName: "x", url: "javascript:alert(1)"),
            WorkspaceResource(kind: .webPage, displayName: "x", url: "ftp://example.org/file"),
            WorkspaceResource(kind: .webPage, displayName: "x", url: nil),
        ]
        let report = WorkspaceLauncher().open(tampered, using: opener)
        #expect(opener.opened.isEmpty)
        #expect(report.problems.map(\.reason) == Array(repeating: .notAWebAddress, count: 4))
    }

    @Test func stalledBookmarksAreWrittenBackToTheSetupNotTheOtherWayRound() throws {
        // The report carries the fresh resource; the model replaces the one
        // with the same id. Nothing else in the setup is touched.
        var setup = FocusSetup(name: "G", resources: [WorkspaceResource(kind: .document, displayName: "A", path: "/a"),
                                                     WorkspaceResource(kind: .document, displayName: "B", path: "/b")])
        var fresh = setup.resources[1]
        fresh.path = "/moved/b"
        setup.replace(fresh.id, with: fresh)
        #expect(setup.resources.map(\.path) == ["/a", "/moved/b"])
    }
}

// MARK: - Addresses

struct WorkspaceAddressTests {
    @Test(arguments: [
        ("example.com/page", "https://example.com/page"),
        ("  http://example.com/Page?Q=1  ", "http://example.com/Page?Q=1"),
        ("HTTPS://Example.com/x", "HTTPS://Example.com/x"),
        ("//example.com/p", "https://example.com/p"),
        ("grants.nih.gov", "https://grants.nih.gov"),
    ])
    func httpAndHttpsAreKept(_ typed: String, _ saved: String) throws {
        let resource = try WorkspaceResource.webPage(from: typed).get()
        #expect(resource.kind == .webPage && resource.url == saved)
        #expect(WorkspaceResource.openableAddress(resource.url) != nil)
    }

    @Test(arguments: [
        "file:///etc/passwd", "javascript:alert(1)", "ftp://example.com/x", "mailto:a@example.com",
        "data:text/html,hello", "https://user:pw@example.com/", "https://example.com@evil.example/",
        "x-apple.systempreferences:com.apple.preference.security", "ssh://host", "https://example.com:99999/",
        "not a url", "http://", "",
    ])
    func everythingElseIsRefused(_ typed: String) {
        let result = WorkspaceResource.webPage(from: typed)
        #expect({ if case .success = result { return false } else { return true } }(), "\(typed) was accepted")
    }

    @Test func blankIsSilentAndAnythingElseSaysWhy() {
        #expect(WorkspaceResource.webPage(from: "   ").failureValue == .empty)
        #expect(WorkspaceResource.AddressProblem.empty.message == nil)
        #expect(WorkspaceResource.webPage(from: "ftp://x.org").failureValue == .notAWebAddress)
        #expect(WorkspaceResource.AddressProblem.notAWebAddress.message?.contains("http or https") == true)
    }

    @Test func aPageIsListedByItsAddressWithoutTheScheme() throws {
        let resource = try WorkspaceResource.webPage(from: "https://www.example.org/guide/aims?v=1").get()
        #expect(resource.displayName == "example.org/guide/aims?v=1")
        let long = try WorkspaceResource.webPage(from: "example.org/" + String(repeating: "a", count: 200)).get()
        #expect(long.displayName.count == 60)
    }

    @Test func theSameAddressIsNotAddedTwiceAndTheListHasALimit() throws {
        var setup = FocusSetup(name: "L")
        let first = setup.add([try page("example.org/a"), try page("example.org/a")])
        #expect(first == 1)
        let many = try (0..<30).map { try page("example.org/p\($0)") }
        setup.add(many)
        #expect(setup.resources.count == FocusSetup.resourceLimit)
        let extra = setup.add([try page("example.org/new")])
        #expect(extra == 0)
    }

    @Test func theSameFileIsNotAddedTwiceWhateverItIsCalled() {
        var setup = FocusSetup(name: "F")
        let a = WorkspaceResource(kind: .document, displayName: "Aims", path: "/tmp/x/Aims.docx")
        let b = WorkspaceResource(kind: .document, displayName: "Renamed in the list", path: "/tmp/x/../x/Aims.docx")
        let added = setup.add([a, b])
        #expect(added == 1)
    }

    @Test func choosingAgainKeepsThePlaceInTheList() {
        let a = WorkspaceResource(kind: .document, displayName: "A", path: "/a")
        let b = WorkspaceResource(kind: .document, displayName: "B", path: "/b")
        let c = WorkspaceResource(kind: .document, displayName: "C", path: "/c")
        var setup = FocusSetup(name: "R", resources: [a, b, c])
        setup.replace(b.id, with: b.choosing(URL(fileURLWithPath: "/elsewhere/B2.docx"), bookmarks: FakeBookmarks()))
        #expect(setup.resources.map(\.id) == [a.id, b.id, c.id])
        #expect(setup.resources[1].path == "/elsewhere/B2.docx")
        // Chosen again as something that is already there: not doubled.
        setup.replace(b.id, with: WorkspaceResource(kind: .document, displayName: "A", path: "/a"))
        #expect(setup.resources.map(\.id) == [a.id, c.id])
    }
}

private extension Result {
    var failureValue: Failure? { if case .failure(let error) = self { return error } else { return nil } }
}

// MARK: - A page its own rules block

struct WorkspaceConflictTests {
    typealias T = FocusSetupTests
    static let video = "https://" + "youtube.com/watch?v=abc"

    static func setup(_ pages: [String], categories: [String] = ["video"], mode: SessionPlan.Mode = .block,
                      exceptions: [WebsiteException] = []) throws -> FocusSetup {
        FocusSetup(name: "Grant", categoryIDs: categories, mode: mode, websiteExceptions: exceptions,
                   resources: try pages.map { try page($0) })
    }

    @Test func aPageItsCategoryBlocksIsAConflictWithTheOneExactFix() throws {
        let conflicts = try Self.setup([Self.video, "example.org/guide"]).conflicts(in: T.categories)
        #expect(conflicts.count == 1, "only the blocked page")
        let c = try #require(conflicts.first)
        #expect(c.blockedBy == ["Video"] && c.reason == "Blocked by Video" && !c.isAllowList)
        #expect(c.sentence == "youtube.com/watch?v=abc is blocked by Video.")
        let fix = try #require(c.fix)
        #expect(fix.kind == .exact && fix.address == "youtube.com/watch?v=abc", "this page, not the site")
    }

    @Test func noConflictWithoutABlockingCategoryOrWithAnException() throws {
        #expect(try Self.setup([Self.video], categories: ["news"]).conflicts(in: T.categories).isEmpty)
        // The category's own exception.
        var categories = T.categories
        let index = try #require(categories.firstIndex { $0.id == "video" })
        categories[index].websiteExceptions = [WebsiteException(kind: .exact, address: "youtube.com/watch?v=abc")]
        #expect(try Self.setup([Self.video]).conflicts(in: categories).isEmpty)
        // The setup's own.
        let own = try Self.setup([Self.video], exceptions: [WebsiteException(kind: .exact, address: "youtube.com/watch?v=abc")])
        #expect(own.conflicts(in: T.categories).isEmpty)
    }

    @Test func allowingOnePageLetsThroughThatPageAndNoMore() throws {
        var setup = try Self.setup([Self.video, "https://" + "youtube.com/watch?v=xyz", "https://" + "youtube.com/feed"])
        let before = setup.conflicts(in: T.categories)
        #expect(before.count == 3)
        let abc = try #require(before.first { $0.address.hasSuffix("v=abc") })
        let allowed = setup.allow(abc)
        #expect(allowed)
        #expect(setup.websiteExceptions == [WebsiteException(kind: .exact, address: "youtube.com/watch?v=abc")])
        let after = setup.conflicts(in: T.categories)
        #expect(after.map(\.page).sorted() == ["youtube.com/feed", "youtube.com/watch?v=xyz"],
                "a different video and the rest of the site stay blocked")
        let again = setup.allow(abc)
        #expect(!again, "a second time adds nothing")
        #expect(setup.websiteExceptions.count == 1)
    }

    @Test func trackingParametersAreLeftOutOfTheFix() throws {
        let tracked = "https://" + "youtube.com/watch?v=abc&utm_source=news&si=Zz9&t=40s"
        let conflict = try #require(try Self.setup([tracked]).conflicts(in: T.categories).first)
        #expect(conflict.fix?.address == "youtube.com/watch?v=abc")
    }

    @Test func anAllowListNamesWhatIsLetThroughSoThereIsNoExceptionToMake() throws {
        // Only Video allowed: a page on another site is blocked, and the
        // video page is let through.
        let setup = try Self.setup(["example.org/guide", Self.video], categories: ["video"], mode: .allow)
        let conflicts = setup.conflicts(in: T.categories)
        #expect(conflicts.count == 1 && conflicts[0].page == "example.org/guide")
        #expect(conflicts[0].isAllowList && conflicts[0].fix == nil)
        #expect(conflicts[0].reason == "Not on the allow list")
        #expect(conflicts[0].sentence == "example.org/guide isn\u{2019}t on the allow list.")
    }

    @Test func theSessionsOwnPlanSaysTheSameThing() throws {
        let setup = try Self.setup([Self.video, "example.org/guide"], categories: ["video", "social"])
        let live = T.categories.filter { setup.categoryIDs.contains($0.id) }
        var p = SessionPlan(goal: "", duration: nil, mode: .block, categories: live, reopensQuitApps: false)
        p.resources = setup.resources
        #expect(p.workspaceConflicts(categories: T.categories).map(\.address) == setup.conflicts(in: T.categories).map(\.address))
        // With the exception frozen into the plan, the page is let through.
        p.websiteExceptions = [WebsiteException(kind: .exact, address: "youtube.com/watch?v=abc")]
        #expect(p.workspaceConflicts(categories: T.categories).isEmpty)
    }

    @Test func startingWithAConflictStillStartsAndTheCardSaysSo() throws {
        let c = try #require(try Self.setup([Self.video]).conflicts(in: T.categories).first)
        let clean = WorkspaceReport(total: 1, opened: 1)
        #expect(NidusModel.workspaceCardTitle(setupName: "Grant writing", report: clean, conflicts: [c])
                == "Grant writing: 1 page is blocked")
        let lines = NidusModel.workspaceCardLines(report: clean, conflicts: [c])
        #expect(lines == ["youtube.com/watch?v=abc is blocked by Video. Allowing it applies from the next start."])
        let allow = try Self.setup([Self.video, "https://" + "reddit.com/r/grants"], categories: ["video", "social"])
            .conflicts(in: T.categories)
        #expect(allow.count == 2)
        #expect(NidusModel.workspaceCardTitle(setupName: "G", report: clean, conflicts: allow) == "G: 2 pages are blocked")
        #expect(NidusModel.workspaceCardLines(report: clean, conflicts: allow).first?.contains("Open the setup to allow the ones you want") == true)
    }

    @MainActor
    @Test func theBlockCardForANamedPageStaysQuietBriefly() {
        let cards = FocusCardState()
        cards.workspaceQuietKeys = ["youtube.com"]
        let now = Date()
        cards.workspaceQuietUntil = now.addingTimeInterval(4)
        #expect(cards.suppressesBlockedCard(for: "youtube.com", now: now))
        #expect(!cards.suppressesBlockedCard(for: "reddit.com", now: now), "other blocks still say so")
        #expect(!cards.suppressesBlockedCard(for: "youtube.com", now: now.addingTimeInterval(5)), "and not for long")
    }
}

// MARK: - The card is sized for its own text

@MainActor
struct WorkspaceCardSizeTests {
    private func size(lines: [String]) -> NSSize {
        let card = HUDCardView(content: AnyView(
            WorkspaceNoticeCard(symbol: "nosign", title: "Grant writing: opened 4 of 5", lines: lines,
                                state: WorkspaceCardState(), openSetup: {}, allow: {})))
        let view = NSHostingView(rootView: card)
        view.frame = NSRect(x: 0, y: 0, width: HUDPresenter.width, height: 10)
        return view.fittingSize
    }

    /// The presenter sizes a card once, from its content's ideal size. Text
    /// that asked for one unwrapped line would get a card too short for it.
    @Test func theCardIsAsWideAsTheHUDAndTallerForMoreText() {
        let one = size(lines: ["Budget.xlsx can\u{2019}t be found. Choose it again in the setup."])
        let two = size(lines: ["Budget.xlsx can\u{2019}t be found. Choose it again in the setup.",
                               "youtube.com/watch?v=9bZkp7q19f0 is blocked by Video. Allowing it applies from the next start."])
        #expect(one.width == HUDPresenter.width && two.width == HUDPresenter.width)
        #expect(two.height > one.height)
        #expect(one.height > 62, "two lines of text and a title do not fit a one-line card")
    }
}


// MARK: - Project and break, each inherit / none / its own

struct SetupProjectAndBreakTests {
    typealias T = FocusSetupTests

    @Test func aZeroPointThreeSetupHasNoProjectOrBreakOfItsOwn() throws {
        let setup = try JSONDecoder().decode(FocusSetup.self, from: Data(WorkspaceStorageTests.legacy.utf8))
        #expect(setup.project == nil && setup.breakMinutes == nil && setup.breakRules == nil)
        let request = setup.request(categories: T.categories, popoverProject: nil)
        #expect(request.projectID == nil && request.breakMinutes == nil && request.breakRules == nil)
    }

    @Test func theProjectIsThePopoversUnlessTheSetupNamesOneOrNone() {
        let popover = UUID(), own = UUID()
        func project(_ choice: SetupProject?) -> UUID? {
            FocusSetup(name: "P", categoryIDs: ["social"], project: choice)
                .request(categories: T.categories, popoverProject: popover).projectID
        }
        #expect(project(nil) == popover, "inherit: the popover's current project")
        #expect(project(.noProject) == nil, "none, even with one chosen in the popover")
        #expect(project(.project(own)) == own)
        // No popover choice (a link, a sequence): inherit is no project.
        #expect(FocusSetup(name: "P", categoryIDs: ["social"]).request(categories: T.categories).projectID == nil)
    }

    @Test func aProjectArchivedOrDeletedSinceCountsAsNone() {
        let live = FocusProject(name: "Live"), archived = FocusProject(name: "Old", isArchived: true)
        func start(_ choice: SetupProject?, popover: UUID? = nil) -> UUID? {
            FocusSetup(name: "P", categoryIDs: ["social"], project: choice)
                .startRequest(categories: T.categories, goalDraft: "", popoverProject: popover, projects: [live, archived]).projectID
        }
        #expect(start(.project(live.id)) == live.id)
        #expect(start(.project(archived.id)) == nil)
        #expect(start(.project(UUID())) == nil, "deleted")
        #expect(start(nil, popover: live.id) == live.id)
        #expect(start(.noProject, popover: live.id) == nil)
    }

    @Test func breakMinutesAreInheritedNoneOrOwn() {
        func minutes(_ value: Int?) -> Int? {
            FocusSetup(name: "B", categoryIDs: ["social"], breakMinutes: value).request(categories: T.categories).breakMinutes
        }
        #expect(minutes(nil) == nil, "Settings' break")
        #expect(minutes(0) == 0, "none, even if Settings has one")
        #expect(minutes(10) == 10)
    }

    @Test func breakRulesAreInheritedNoneOrOwn() {
        func rules(_ value: BreakRules?) -> BreakRules? {
            FocusSetup(name: "B", categoryIDs: ["social"], breakRules: value).request(categories: T.categories).breakRules
        }
        #expect(rules(nil) == nil, "Settings' default rules")
        #expect(rules(BreakRules()) == BreakRules(), "an unrestricted break, as an explicit value")
        #expect(rules(BreakRules(websites: ["x.com"], reminder: "Stretch"))?.websites == ["x.com"])
    }

    @Test func theThreeStatesSurviveARoundTripAndABadValueLosesOnlyItself() throws {
        let setup = FocusSetup(name: "R", project: .noProject, breakMinutes: 0, breakRules: BreakRules())
        let back = try JSONDecoder().decode(FocusSetup.self, from: JSONEncoder().encode(setup))
        #expect(back.project == .noProject && back.breakMinutes == 0 && back.breakRules == BreakRules())
        let id = UUID()
        let own = FocusSetup(name: "O", project: .project(id), breakMinutes: 15, breakRules: BreakRules(apps: ["a"], reminder: "Water"))
        #expect(try JSONDecoder().decode(FocusSetup.self, from: JSONEncoder().encode(own)) == own)

        let json = #"""
        {"id":"\#(UUID().uuidString)","name":"Odd","minutes":30,"project":"zzz","breakMinutes":"ten","breakRules":5}
        """#
        let odd = try JSONDecoder().decode(FocusSetup.self, from: Data(json.utf8))
        #expect(odd.name == "Odd" && odd.minutes == 30)
        #expect(odd.project == nil && odd.breakMinutes == nil && odd.breakRules == nil, "each reads as inherit")
        let long = #"{"id":"\#(UUID().uuidString)","name":"Long","breakMinutes":99999}"#
        #expect(try JSONDecoder().decode(FocusSetup.self, from: Data(long.utf8)).breakMinutes == FocusSetup.breakMinutesLimit)
    }

    @Test func theSummariesSayWhatEachLineUses() {
        let live = FocusProject(name: "R01 renewal"), old = FocusProject(name: "Teaching", isArchived: true)
        var setup = FocusSetup(name: "S")
        #expect(setup.projectSummary(in: [live]) == "Uses the popover\u{2019}s")
        #expect(setup.breakSummary == "Uses Settings" && setup.breakRulesSummary(categories: T.categories, appName: { $0 }) == "Uses Settings")
        setup.project = .noProject
        #expect(setup.projectSummary(in: [live]) == "No project")
        setup.project = .project(live.id)
        #expect(setup.projectSummary(in: [live, old]) == "R01 renewal")
        setup.project = .project(old.id)
        #expect(setup.projectSummary(in: [live, old]) == "Teaching (archived)")
        setup.project = .project(UUID())
        #expect(setup.projectSummary(in: [live]).hasSuffix("(deleted)") || setup.projectSummary(in: [live]) == "A deleted project")
        setup.breakMinutes = 0
        #expect(setup.breakSummary == "No break")
        setup.breakMinutes = 90
        #expect(setup.breakSummary == "1 hr 30 min")
        setup.breakRules = BreakRules()
        #expect(setup.breakRulesSummary(categories: T.categories, appName: { $0 }) == "Nothing blocked")
        setup.breakRules = BreakRules(websites: ["x.com"])
        #expect(setup.breakRulesSummary(categories: T.categories, appName: { $0 }) == "x.com")
        setup.breakRules = BreakRules(reminder: "Water")
        #expect(setup.breakRulesSummary(categories: T.categories, appName: { $0 }) == "Reminder only")
    }

    @MainActor
    @Test func theBreakPickerKeepsAnOwnLengthItDoesNotListByDefault() {
        #expect(SetupWorkspaceSections.breakChoices(including: nil) == [5, 10, 15])
        #expect(SetupWorkspaceSections.breakChoices(including: 10) == [5, 10, 15])
        #expect(SetupWorkspaceSections.breakChoices(including: 20) == [5, 10, 15, 20])
        #expect(SetupWorkspaceSections.breakChoices(including: 0) == [5, 10, 15])
    }

    @Test func theResolutionPassesAllThreeToThePlan() throws {
        let defaults = StartDefaults(mode: .block, selectedCategoryIDs: [], categories: T.categories,
                                     defaultBreakRules: BreakRules(websites: ["x.com"]), projectName: { _ in "R01" })
        let project = UUID()
        func plan(_ setup: FocusSetup) throws -> SessionPlan {
            try #require(setup.request(categories: T.categories).resolved(with: defaults, length: { (25, false) })?.plan)
        }
        let own = try plan(FocusSetup(name: "O", categoryIDs: ["social"], project: .project(project), breakMinutes: 5,
                                      breakRules: BreakRules(apps: ["a"])))
        #expect(own.projectID == project && own.projectName == "R01" && own.breakLength == 300 && own.breakRules == BreakRules(apps: ["a"]))
        let none = try plan(FocusSetup(name: "N", categoryIDs: ["social"], project: .noProject, breakMinutes: 0, breakRules: BreakRules()))
        #expect(none.projectID == nil && none.breakLength == 0 && none.breakRules == BreakRules())
        let inherit = try plan(FocusSetup(name: "I", categoryIDs: ["social"]))
        #expect(inherit.breakLength == nil && inherit.breakRules == BreakRules(websites: ["x.com"]))
    }
}

// MARK: - A sequence block from a workspace setup

@MainActor
struct WorkspaceSequenceTests {
    typealias T = FocusSetupTests

    private func defaults() -> StartDefaults {
        StartDefaults(mode: .block, selectedCategoryIDs: ["social"], categories: T.categories,
                      projectName: { _ in "R01 renewal" })
    }

    private func resolve(_ sequence: FocusSequence, setups: [FocusSetup]) throws -> SequenceRun {
        let d = defaults()
        return try #require(sequence.resolved(startedAt: Date(), request: {
            sequence.request(for: $0, setups: setups, categories: T.categories, projectExists: { _ in true })
        }, plan: { $0.resolved(with: d, length: { (25, false) })?.plan }))
    }

    @Test func aBlockFromAWorkspaceSetupCarriesItsResourcesAndOpensThemWhenThatBlockStarts() throws {
        let w = try Workspace()
        let aims = WorkspaceResource.file(at: try w.file("Aims.docx"), bookmarks: FakeBookmarks())
        let notes = WorkspaceResource.file(at: try w.file("Notes.md"), bookmarks: FakeBookmarks())
        let writing = FocusSetup(name: "Writing", categoryIDs: ["social"],
                                 launchApps: [BlockedApp(bundleID: "com.microsoft.Word", name: "Word")],
                                 startShortcut: "Focus on", resources: [aims, try page("example.org/guide")])
        let review = FocusSetup(name: "Review", categoryIDs: ["social"], resources: [notes])
        let sequence = FocusSequence(steps: [.work(minutes: 25, goal: "Write", setupID: writing.id), .rest(minutes: 5),
                                             .work(minutes: 25, goal: "Review", setupID: review.id)])
        let run = try resolve(sequence, setups: [writing, review])

        // Resolved, each block holds its setup's workspace and is not a continuation.
        guard case .work(let first) = run.steps[0], case .work(let second) = run.steps[2] else { Issue.record("shape"); return }
        #expect(first.resources == writing.resources && first.launchApps == ["com.microsoft.Word"] && first.startShortcut == "Focus on")
        #expect(second.resources == [notes])
        #expect(!first.isContinuation && !second.isContinuation)
        #expect(first.setupID == writing.id && second.setupID == review.id)

        // Started on a controller with a fake Mac and a clock moved by hand.
        let clock = TestClock()
        let (controller, opener) = WorkspaceLaunchTests.controller(in: w.root.appendingPathComponent("state"), now: { clock.now })
        var reports: [SessionPlan] = []
        controller.onWorkspaceOpened = { _, plan in reports.append(plan) }
        controller.start()
        defer { controller.end(); controller.stop() }
        #expect(controller.startSequence(run))
        #expect(opener.opened.map(\.lastPathComponent) == ["Aims.docx", "guide"], "the first block opens its own")
        #expect(opener.apps == [["com.microsoft.Word"]])

        // The first block completes and the break runs out: the second block
        // is a start of its own, so it opens its setup's workspace, once.
        clock.advance(25 * minute)
        controller.engine.tick()
        #expect(controller.engine.isOnBreak)
        #expect(opener.opened.count == 2, "nothing opens during the break")
        clock.advance(5 * minute)
        controller.engine.tick()
        #expect(controller.engine.session?.plan.isContinuation == false)
        #expect(opener.opened.map(\.lastPathComponent) == ["Aims.docx", "guide", "Notes.md"])
        #expect(reports.map(\.setupID) == [writing.id, review.id])
    }

    @Test func aSetupsProjectAndBreakFlowIntoItsBlocksAndAStepsOwnProjectWins() throws {
        let mine = UUID(), steps = UUID()
        let setup = FocusSetup(name: "Writing", categoryIDs: ["social"], project: .project(mine), breakMinutes: 10)
        let inherited = try resolve(FocusSequence(steps: [.work(setupID: setup.id)]), setups: [setup])
        guard case .work(let a) = inherited.steps[0] else { return }
        #expect(a.projectID == mine && a.breakLength == 600)
        let overridden = try resolve(FocusSequence(steps: [.work(setupID: setup.id, projectID: steps)]), setups: [setup])
        guard case .work(let b) = overridden.steps[0] else { return }
        #expect(b.projectID == steps)
        // A setup that follows the popover has no popover here: no project.
        let follows = FocusSetup(name: "Follows", categoryIDs: ["social"])
        let none = try resolve(FocusSequence(steps: [.work(setupID: follows.id)]), setups: [follows])
        guard case .work(let c) = none.steps[0] else { return }
        #expect(c.projectID == nil)
    }
}
