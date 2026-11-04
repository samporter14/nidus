import AppKit
import SwiftUI

/// Owns a presentation only while it is open. Composer values live in the
/// model, so releasing the hosting tree never discards an unfinished goal.
@MainActor
final class FocusPopoverPresentation: NSObject, NSPopoverDelegate {
    private(set) var popover: NSPopover?

    func prepare(model: NidusModel) -> NSPopover {
        if let popover { return popover }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hosting = NSHostingController(rootView: NidusPopover(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        self.popover = popover
        return popover
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closing = notification.object as? NSPopover, closing === popover else { return }
        release(closing)
    }

    func close() {
        guard let popover else { return }
        popover.close()
        // Shutdown also releases a presentation prepared but never shown.
        if self.popover === popover { release(popover) }
    }

    private func release(_ closing: NSPopover) {
        closing.contentViewController = nil
        closing.delegate = nil
        popover = nil
    }
}
