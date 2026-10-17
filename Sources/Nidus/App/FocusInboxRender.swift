//
//  FocusInboxRender.swift
//  Nidus
//
//  `--render-surfaces` for the inbox: the Inbox page full and empty, General's
//  link to it, the capture panel in each of its states, the popover with its
//  row, and the wrap-up card with a count of what was saved. Everything here
//  uses the demo's throwaway folder; no real inbox, link or hot key is touched.
//

import AppKit
import SwiftUI

extension NidusModel {
    /// A web address for the samples, built from its parts: a literal would
    /// be a web address in code, which PrivacyTests refuses.
    private static func sampleAddress(_ host: String, _ path: String, query: String? = nil) -> String {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.path = path
        parts.query = query
        return parts.string ?? ""
    }

    /// Four items in the demo's inbox and one finished. Demo only.
    func seedSampleInbox() {
        guard Demo.isActive, let inbox else { return }
        inbox.clear()
        inbox.add(text: "Email Dana about the plate reader booking")
        inbox.add(text: "", link: Self.sampleAddress("www.youtube.com", "/watch", query: "v=dQw4w9WgXcQ"), source: .blockedPage)
        inbox.add(text: "Is the p-value in figure 2 corrected for multiple tests?",
                  link: Self.sampleAddress("example.org", "/methods/multiple-testing"), source: .capture)
        if case .added(let done, _) = inbox.add(text: "Renew the Zotero subscription") {
            inbox.setCompleted(done.id, true)
        }
    }
}

extension RenderSurfaces {
    static func renderInbox(model: NidusModel, settings: SettingsWindowController, host: NidusHost, in directory: URL) async {
        // The demo's settings are shared with every other demo run and emptied
        // at each launch, so the shortcut is put back just before it is drawn.
        func stage(shortcut: Bool = true) {
            model.captureShortcut = shortcut ? KeyShortcut(keyCode: 49, modifiers: [.control, .option], key: "Space") : nil
        }

        model.runHarnessScenario("inbox")
        stage()
        await shootSettings(model, settings, page: NidusModel.inboxPageID, title: "Inbox",
                            name: "settings-inbox", height: 900, in: directory)
        await shootSettings(model, settings, tab: .general, name: "settings-general-inbox", height: 1500, in: directory)
        await shootWindow(settings, page: NidusModel.inboxPageID, title: "Inbox", name: "settings-window-inbox", in: directory)
        settings.window?.orderOut(nil)
        settings.router(for: .general).reset()

        // The popover with items waiting: idle, running, on a break.
        for scenario in ["idle", "running", "break"] {
            model.runHarnessScenario(scenario)
            if scenario == "idle" { model.goalDraft = "" }
            model.seedSampleInbox()
            await shoot(NidusPopover(model: model), width: 440, name: "popover-\(scenario)-inbox", in: directory)
        }

        // The popover's row on its own, over a background that draws in both
        // appearances (the popover itself has none off-screen), and one
        // finished item as the Done list shows it.
        for scenario in ["running", "idle"] {
            model.runHarnessScenario(scenario)
            model.seedSampleInbox()
            await shoot(FocusInboxRow(model: model), width: 400, name: "inbox-row-\(scenario)", in: directory, padded: true)
        }
        if let done = model.inbox?.completedItems.first, let open = model.inbox?.openItems.first {
            await shoot(VStack(alignment: .leading, spacing: 12) {
                InboxItemRow(item: open, toggle: {}, open: {}, delete: {})
                InboxItemRow(item: done, toggle: {}, open: {}, delete: {})
            }.fixedSize(horizontal: false, vertical: true), width: 520, name: "inbox-rows", in: directory, padded: true)
        }

        // Nothing saved yet, and no shortcut.
        model.runHarnessScenario("idle")
        model.inbox?.clear()
        stage(shortcut: false)
        await shootSettings(model, settings, page: NidusModel.inboxPageID, title: "Inbox",
                            name: "settings-inbox-empty", height: 700, in: directory)

        // The capture panel: empty, typed, a link it keeps, a link it
        // doesn't, already saved, and close to the limit.
        let draft = CaptureDraft()
        func panel(_ name: String) async {
            await shoot(FocusCaptureView(draft: draft, save: {}, cancel: {}), width: CaptureCoordinator.width,
                        name: "capture-\(name)", in: directory, padded: true)
        }
        await panel("empty")
        draft.text = "Check whether the gel images need the scale bars redone"
        await panel("typed")
        draft.link = "example.org/protocols/gels"
        await panel("with-link")
        draft.link = "javascript:alert(1)"
        await panel("link-refused")
        draft.link = "example.org/protocols/gels"
        draft.note = "That link is already in your inbox."
        await panel("duplicate")
        draft.note = nil
        draft.text = String(repeating: "A long thought about the revision. ", count: 8).trimmingCharacters(in: .whitespaces)
        draft.text = String(draft.text.prefix(FocusInbox.textLimit - 10))
        draft.link = ""
        await panel("near-limit")

        // The wrap-up card with a count, alone, with its question, and with a break.
        model.runHarnessScenario("wrapup-saved")
        if let request = host.hud.lastRequest {
            await shoot(HUDCardView(content: request.content), width: HUDPresenter.width,
                        name: "card-wrapup-saved", in: directory, padded: true)
        }
        model.runHarnessScenario("finish-saved")
        if let request = host.hud.lastRequest {
            await shoot(HUDCardView(content: request.content), width: HUDPresenter.width,
                        name: "card-finish-saved", in: directory, padded: true)
        }
        model.runHarnessScenario("idle")
        model.inbox?.clear()
        model.captureShortcut = nil
    }
}
