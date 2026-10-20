#if DEBUG
//
//  FocusJumpRender.swift
//  Nidus
//
//  `--render-surfaces` for Jump to and the Open Nidus shortcut: General with
//  the shortcut set, the field with a query over a tab and over the whole
//  window, a choice moved down, and a query that finds nothing. The demo's own
//  settings only; no hot key is registered (the coordinator does nothing in a
//  demo).
//

import AppKit
import SwiftUI

extension RenderSurfaces {
    static func renderJump(model: NidusModel, settings: SettingsWindowController, in directory: URL) async {
        let jump = model.settingsJump
        model.runHarnessScenario("idle")

        // General with both shortcuts set: Open Nidus in Menu bar and login.
        model.captureShortcut = KeyShortcut(keyCode: 49, modifiers: [.control, .option], key: "Space")
        model.openShortcut = KeyShortcut(keyCode: 45, modifiers: [.control, .option], key: "N")
        await shootSettings(model, settings, tab: .general, name: "settings-general-open-shortcut", height: 1300, in: directory)
        model.openShortcut = nil
        await shootSettings(model, settings, tab: .general, name: "settings-general-open-shortcut-off", height: 1300, in: directory)
        model.captureShortcut = nil

        // The field with a query: the first row chosen, then the second.
        jump.query = "break"
        await shootSettings(model, settings, tab: .general, name: "settings-jump-break", height: 600, in: directory)
        jump.query = "shortcut"
        jump.move(1)
        await shootSettings(model, settings, tab: .setups, name: "settings-jump-shortcut", height: 600, in: directory)
        jump.query = "calendar"
        await shootSettings(model, settings, tab: .stats, name: "settings-jump-calendar", height: 600, in: directory)
        jump.query = "zzzz"
        await shootSettings(model, settings, tab: .general, name: "settings-jump-none", height: 600, in: directory)

        // The window itself, toolbar and field.
        jump.query = "exceptions"
        await shootWindow(settings, page: SettingsTab.general.pageID, name: "settings-window-jump", in: directory)
        settings.window?.orderOut(nil)
        jump.clear()
    }
}

#endif
