import Foundation
import Testing
@testable import Nidus

/// Coding apps' window titles, cut down to the project they name.
@Suite("Project names from coding apps")
struct ActivityProjectTitleTests {
    private let home = "/Users/sam"

    private func project(_ title: String?, _ app: String) -> String? {
        ActivityProjectTitle.project(from: title, bundleID: app, home: home)
    }

    @Test func xcodeKeepsTheProjectNotTheFile() {
        let xcode = ActivityProjectTitle.xcodeID
        #expect(project("Nidus — FocusActivityPage.swift", xcode) == "Nidus")
        #expect(project("Nidus — Edited", xcode) == "Nidus")
        #expect(project("Nidus", xcode) == "Nidus")
        #expect(project("Capsid.xcworkspace — AppDelegate.swift", xcode) == "Capsid")
        #expect(project("Welcome to Xcode", xcode) == nil)
        #expect(project("Devices and Simulators", xcode) == nil)
        #expect(project("", xcode) == nil)
        #expect(project(nil, xcode) == nil)
    }

    @Test func vsCodeKeepsTheFolder() {
        let code = "com.microsoft.VSCode"
        #expect(project("● FocusActivityPage.swift — nidus — Visual Studio Code", code) == "nidus")
        #expect(project("README.md — site (Workspace) — Visual Studio Code", code) == "site")
        #expect(project("nidus — Visual Studio Code", code) == "nidus")
        #expect(project("[SSH: devbox] main.py — api — Visual Studio Code", code) == "api")
        #expect(project("Welcome — Visual Studio Code", code) == nil)
        #expect(project("main.py — Visual Studio Code", code) == nil, "a file with no folder open")
        #expect(project("Untitled-1 — Visual Studio Code", code) == nil)
        #expect(project("Settings — nidus — Visual Studio Code", code) == "nidus")
        #expect(project("Extension: Swift — Visual Studio Code", code) == nil)
    }

    @Test func cursorReadsLikeVSCode() {
        let cursor = ActivityProjectTitle.cursorID
        #expect(project("page.tsx — web-app — Cursor", cursor) == "web-app")
        #expect(project("page.tsx - web-app - Cursor", cursor) == "web-app")
        #expect(project("web-app — Cursor", cursor) == "web-app")
        #expect(project("Cursor Settings — Cursor", cursor) == nil)
    }

    @Test func terminalKeepsTheWorkingFolder() {
        let terminal = ActivityProjectTitle.terminalID
        #expect(project("nidus — -zsh — 80×24", terminal) == "nidus")
        #expect(project("nidus — swift-build ◂ zsh — 120×40", terminal) == "nidus")
        #expect(project("sam — -zsh — 80×24", terminal) == nil, "the home folder is no project")
        #expect(project("sam@mac: ~/Documents/nidus", terminal) == "nidus")
        #expect(project("sam@mac: ~", terminal) == nil)
        #expect(project("-zsh", terminal) == nil)
        #expect(project("-zsh — 80×24", terminal) == nil)
        #expect(project("Build log", terminal) == nil, "a custom one-piece title")
    }

    @Test func iTermKeepsTheWorkingFolder() {
        let iterm = ActivityProjectTitle.iTermID
        #expect(project("nidus (-zsh)", iterm) == "nidus")
        #expect(project("~/Documents/Default Project/nidus (zsh)", iterm) == "nidus")
        #expect(project("~ (zsh)", iterm) == nil)
        #expect(project("-zsh", iterm) == nil)
        #expect(project("vim", iterm) == nil)
    }

    @Test func otherAppsAreNotRead() {
        #expect(project("nidus — Visual Studio Code", "com.apple.Safari") == nil)
        #expect(!ActivityProjectTitle.isProjectApp("com.apple.Safari"))
        #expect(ActivityProjectTitle.isProjectApp(ActivityProjectTitle.xcodeID))
    }

    @Test func namesGetTheUsualCleaning() {
        let code = "com.microsoft.VSCode"
        #expect(project("x — https://example.com — Visual Studio Code", code) == nil)
        #expect(project("x — " + String(repeating: "a", count: 120) + " — Visual Studio Code", code) == nil)
    }

    @Test func probeReadsCodingAppsOnlyWithNamesOn() {
        #expect(ActivityProbe.needsProbe(ActivityProjectTitle.xcodeID, titles: true))
        #expect(!ActivityProbe.needsProbe(ActivityProjectTitle.xcodeID, titles: false))
        #expect(ActivityProbe.detail(bundleID: ActivityProjectTitle.terminalID, pid: 0, titles: false) == nil)
    }

    @Test func aProjectIsOneEntryAcrossCodingApps() {
        let day = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let rows: [(day: Date, row: FocusActivity)] = [
            (day, FocusActivity(appID: ActivityProjectTitle.xcodeID, appName: "Xcode", title: "nidus", seconds: 1800)),
            (day, FocusActivity(appID: ActivityProjectTitle.terminalID, appName: "Terminal", title: "nidus", seconds: 600)),
            (day, FocusActivity(appID: ActivityProjectTitle.terminalID, appName: "Terminal", title: "capsid", seconds: 300)),
            (day, FocusActivity(appID: "com.apple.iWork.Pages", appName: "Pages", title: "nidus", seconds: 120)),
        ]
        let totals = ActivityTotals(rows: rows, focused: 0)
        let nidus = totals.documents.first { $0.subtitle?.hasPrefix("Project") == true && $0.name == "nidus" }
        #expect(nidus?.seconds == 2400)
        #expect(nidus?.subtitle == "Project · Xcode, Terminal")
        #expect(nidus?.appID == ActivityProjectTitle.xcodeID, "counts as the app it had most time in")
        #expect(totals.documents.contains { $0.name == "capsid" && $0.subtitle == "Project · Terminal" })
        #expect(totals.documents.contains { $0.name == "nidus" && $0.subtitle == "Pages" }, "a document of the same name stays apart")
        // The app row still expands into its projects.
        #expect(totals.appDetails[ActivityProjectTitle.terminalID]?.map(\.name) == ["nidus", "capsid"])
    }
}
