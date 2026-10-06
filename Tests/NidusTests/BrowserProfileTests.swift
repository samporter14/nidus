//
//  BrowserProfileTests.swift
//  NidusTests
//
//  The four-character codes each browser is scripted with. A wrong one never
//  fails loudly: the browser's sites simply stay open. So the codes are held
//  against the browser's own scripting dictionary wherever it is installed
//  (a file read, never an Apple Event, and nothing is launched), and the
//  shape of every entry is checked everywhere.
//

import AppKit
import Foundation
import Testing
@testable import Nidus

struct BrowserProfileShapeTests {
    @Test func everyCodeIsExactlyFourASCIIBytes() {
        // Catches `"URL"` for `"URL "`, which Apple Events would not accept.
        for browser in BrowserProfile.known {
            for code in [browser.tabClass, browser.urlProperty] {
                #expect(code.utf8.count == 4 && code.allSatisfy(\.isASCII), "\(browser.name): \"\(code)\"")
            }
        }
    }

    @Test func browsersAreListedOnce() {
        let known = BrowserProfile.known
        #expect(Set(known.map(\.bundleID)).count == known.count)
        #expect(Set(known.map(\.name)).count == known.count)
    }

    @Test func theCodesAreThoseReadFromEachBrowser() {
        // Read from the installed apps' own .sdef files.
        #expect(BrowserProfile.safari.tabClass == "bTab" && BrowserProfile.safari.urlProperty == "pURL")
        #expect(BrowserProfile.chrome.tabClass == "CrTb" && BrowserProfile.chrome.urlProperty == "URL ")
        #expect(BrowserProfile.operaAir.tabClass == "OpTb", "Opera is not Chrome")
        // From the published source: Chromium's dictionary, shipped unchanged.
        for browser in [BrowserProfile.chromium, .brave] {
            #expect(browser.tabClass == "CrTb" && browser.urlProperty == "URL ", "\(browser.name)")
        }
    }

    @Test func everyBundleIDIsTheBrowsersOwn() {
        let ids = Dictionary(uniqueKeysWithValues: BrowserProfile.known.map { ($0.name, $0.bundleID) })
        #expect(ids["Chromium"] == "org.chromium.Chromium")
        #expect(ids["Brave Browser"] == "com.brave.Browser")
        #expect(ids["Opera Air"] == "com.operasoftware.OperaAir")
    }
}

struct InstalledBrowserDictionaryTests {
    /// The installed browser's dictionary, if it is installed. Nothing here
    /// starts the app.
    private static func dictionary(of browser: BrowserProfile) -> XMLDocument? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID),
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let name = info["OSAScriptingDefinition"] as? String else { return nil }
        let file = name.hasSuffix(".sdef") ? name : name + ".sdef"
        return try? XMLDocument(contentsOf: app.appendingPathComponent("Contents/Resources/\(file)"),
                                options: [.nodeLoadExternalEntitiesNever])
    }

    private static func code(_ xpath: String, in document: XMLDocument) -> String? {
        (try? document.nodes(forXPath: xpath))?.first?.stringValue
    }

    /// Passes for a browser that is not installed here; on a Mac that has it,
    /// the profile must match its dictionary exactly.
    @Test(arguments: BrowserProfile.known)
    func theProfileMatchesTheInstalledDictionary(_ browser: BrowserProfile) {
        guard let document = Self.dictionary(of: browser) else { return }
        // Safari takes its window class from the system's standard suite
        // rather than defining it, and that one is `cwin` with `ID  ` too.
        if Self.code("//class[@name='window']/@code", in: document) != nil {
            #expect(Self.code("//class[@name='window']/@code", in: document) == "cwin", "\(browser.name): window class")
            #expect(Self.code("//class[@name='window']/property[@name='id']/@code", in: document) == "ID  ", "\(browser.name): window id")
        }
        #expect(Self.code("//class[@name='tab']/@code", in: document) == browser.tabClass, "\(browser.name): tab class")
        #expect(Self.code("//class[@name='tab']/property[@name='URL']/@code", in: document) == browser.urlProperty,
                "\(browser.name): tab URL")
    }
}
