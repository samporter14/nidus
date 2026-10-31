//
//  WidgetSnapshotTests.swift
//  NidusTests
//
//  widget.json, the one file the widget extension reads, and the links its
//  buttons open. The extension itself is built by Scripts/build-app.sh.
//

import Foundation
import Testing
@testable import Nidus

struct WidgetSnapshotTests {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func roundTripsThroughJSON() throws {
        let snapshot = WidgetSnapshot(state: .focusing, goal: "Write", endsAt: 1_800_000_000, strict: true,
                                      setups: [.init(id: "A", name: "Deep work", symbol: "brain")])
        let back = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(back == snapshot)
        #expect(back.endDate == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func buttonsAreNidusLinksTheAppUnderstands() throws {
        let id = UUID().uuidString
        let url = WidgetSnapshot.startURL(setupID: id)
        #expect(url.absoluteString == "nidus://start?preset=\(id)")
        guard case .success(.start(let start)) = NidusLink.parse(url) else {
            Issue.record("the start link doesn't parse"); return
        }
        #expect(start.preset == id)
        #expect(NidusLink.parse(WidgetSnapshot.endURL) == .success(.end))
        #expect(NidusLink.parse(WidgetSnapshot.popoverURL) == .success(.popover))
    }

    @Test func theExtensionIsSandboxedAndReadsOnlyNidusFolder() throws {
        let entitlements = try #require(NSDictionary(contentsOf: root.appendingPathComponent("Widget/NidusWidget.entitlements")))
        #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(entitlements["com.apple.security.network.client"] == nil)
        #expect(entitlements["com.apple.security.application-groups"] == nil)
        let paths = entitlements["com.apple.security.temporary-exception.files.home-relative-path.read-only"] as? [String]
        #expect(paths == ["/Library/Application Support/Nidus/"])
    }

    @Test func theExtensionBelongsToTheApp() throws {
        let app = try #require(NSDictionary(contentsOf: root.appendingPathComponent("Resources/Info.plist")))
        let widget = try #require(NSDictionary(contentsOf: root.appendingPathComponent("Widget/Info.plist")))
        let appID = try #require(app["CFBundleIdentifier"] as? String)
        #expect((widget["CFBundleIdentifier"] as? String)?.hasPrefix(appID + ".") == true)
        #expect((widget["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String == "com.apple.widgetkit-extension")
    }
}
