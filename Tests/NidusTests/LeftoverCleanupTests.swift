import Foundation
import Testing
@testable import Nidus

@MainActor
struct LeftoverCleanupTests {
    // Plaque sharing was removed; installs that used it still carry its file and settings.
    @Test func launchRemovesTheOldPlaqueFileAndSettings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nidus-leftover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = "local.sam.nidus.tests.leftover"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let preferences = NidusHost.Preferences(defaults: defaults)
        let old = dir.appendingPathComponent("plaque-focus.json")
        let focus = dir.appendingPathComponent("focus.json")
        try Data("{}".utf8).write(to: old)
        try Data("{}".utf8).write(to: focus)
        for key in ["plaqueFocus", "plaqueFocusText", "plaqueFocusRevision"] { preferences.setValueQuietly(true, forKey: key) }
        preferences.setValueQuietly(true, forKey: "kept")

        NidusModel.removePlaqueLeftovers(directory: dir, preferences: preferences)
        NidusModel.removePlaqueLeftovers(directory: dir, preferences: preferences)  // nothing left: still fine

        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: focus.path), "focus.json is for other apps and stays")
        for key in ["plaqueFocus", "plaqueFocusText", "plaqueFocusRevision"] {
            #expect(defaults.object(forKey: key) == nil, "\(key)")
        }
        #expect(preferences.value(forKey: "kept", default: false))
    }
}
