//
//  PrivacyTests.swift
//  NidusTests
//
//  What the README promises, held in place: Nidus never
//  touches the network, its block page loads nothing from anywhere, and
//  between sessions it does nothing at all.
//

import Foundation
import Testing
@testable import Nidus

struct NoNetworkTests {
    /// Every Swift file of the app, core and surfaces.
    static let dropletSources: [URL] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Nidus")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return files.sorted { $0.path < $1.path }
    }()

    @Test func theScanSeesTheWholeDroplet() {
        let names = Set(Self.dropletSources.map(\.lastPathComponent))
        #expect(names.isSuperset(of: ["NidusApp.swift", "NidusModel.swift", "FocusSettings.swift", "FocusController.swift", "BrowserBlocker.swift"]))
    }

    @Test(arguments: [
        "URLSession", "NSURLConnection", "URLRequest", "NWConnection", "NWListener", "NWPathMonitor",
        "import Network", "import WebKit", "WKWebView", "CFStream", "CFHTTP", "socket(", "getaddrinfo",
    ])
    func noNetworkingAPI(_ api: String) throws {
        // A whole name: DroppyKit's DropletURLRequest is a droppy:// link
        // handed to the droplet, not a network request.
        let pattern = try Regex("(^|[^A-Za-z])" + NSRegularExpression.escapedPattern(for: api))
        for file in Self.dropletSources {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains(pattern), "\(file.lastPathComponent) uses \(api)")
        }
    }

    /// Web addresses may appear in comments, as examples, and nowhere else.
    /// A bare scheme is fine: typed domains get one so they can be parsed.
    @Test func noWebAddressesInCode() throws {
        let address = /https?:\/\/[A-Za-z0-9]/
        for file in Self.dropletSources {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                #expect(!code.contains(address),
                        "\(file.lastPathComponent):\(index + 1) has a web address in code")
            }
        }
    }

    @Test func theBlockPageLoadsNothingFromAnywhere() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("focus-privacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = BlockPage(directory: dir, dropletID: "focus")
        try page.install()
        let html = try String(contentsOf: page.fileURL, encoding: .utf8).lowercased()
        // `new URL(...)` in its script only parses the blocked address.
        for remote in ["http://", "https://", "src=\"//", "href=\"//", "@import", "<link", "<img", "<iframe", "fetch(", "xmlhttprequest", "sendbeacon"] {
            #expect(!html.contains(remote), "the block page contains \(remote)")
        }
    }
}

// MARK: - No shell

struct NoShellTests {
    static let sources = NoNetworkTests.dropletSources

    /// The only child process Nidus starts is `/usr/bin/shortcuts`, from
    /// FocusShortcuts, with the Shortcut's name as one argument.
    @Test func onlyFocusShortcutsStartsAProcess() throws {
        for file in Self.sources where file.lastPathComponent != "FocusShortcuts.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for needle in ["Process()", "NSTask", "NSAppleScript", "osascript", "/bin/sh", "/bin/zsh", "/bin/bash", "posix_spawn", "popen("] {
                let hits = text.components(separatedBy: .newlines).filter {
                    !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && $0.contains(needle)
                }
                #expect(hits.isEmpty, "\(file.lastPathComponent) uses \(needle)")
            }
        }
    }

    @Test func theWorkspaceOpensThingsOnlyThroughTheOpener() throws {
        let names: Set<String> = ["WorkspaceLauncher.swift", "FocusWorkspace.swift", "FocusSetupWorkspaceViews.swift"]
        for file in Self.sources where names.contains(file.lastPathComponent) {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("FocusShortcuts.execute"), "\(file.lastPathComponent) runs the tool itself")
            if file.lastPathComponent != "WorkspaceLauncher.swift" {
                #expect(!text.contains("NSWorkspace"), "\(file.lastPathComponent) opens something itself")
            }
        }
        // And the controller does not call NSWorkspace to open a workspace.
        let controller = try String(contentsOf: Self.sources.first { $0.lastPathComponent == "FocusController.swift" }!, encoding: .utf8)
        #expect(!controller.contains("openApplication(") && !controller.contains(".open(url"))
    }
}

@MainActor
struct IdleTests {
    @Test func theClockRunsOnlyDuringASession() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("focus-idle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = FocusController(directory: dir)
        controller.start()
        #expect(!controller.isClockRunning, "between sessions nothing runs")

        // Block mode with nothing listed: acts on no app and asks no browser.
        let plan = SessionPlan(goal: "", duration: 25 * 60, mode: .block, apps: [], websites: [])
        controller.start(plan)
        #expect(controller.isClockRunning)
        controller.pause()
        #expect(controller.isClockRunning, "a paused session still has snoozes to run out")
        controller.resume()
        controller.end()
        #expect(!controller.isClockRunning, "it stops with the session")

        controller.start(plan)
        controller.stop()
        #expect(!controller.isClockRunning, "and when Focus is unloaded")
        controller.start()
        #expect(controller.isClockRunning, "and resumes with a session that outlived a relaunch")
        controller.end()
        #expect(!controller.isClockRunning)
        controller.stop()
    }
}
