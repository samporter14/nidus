//
//  HUDPresenter.swift
//  Nidus
//
//  The cards: something was blocked, a session ended, a break is ending.
//  They drop in at the top of the screen, in the middle, where the notch is,
//  stay a few seconds, and go. Liquid Glass, like the Mac's own banners. One at a time; a new card replaces the one
//  showing. They never take focus from what you are doing, but their
//  buttons work, and a card stays while the pointer is over it.
//

import AppKit
import SwiftUI

@MainActor
final class HUDPresenter {
    private var panel: CardPanel?
    /// The card's window, for `--capture-surfaces`.
    var windowNumber: Int? { panel?.windowNumber }
    private var shownID: String?
    private var dismissTask: Task<Void, Never>?
    /// The last card asked for, for `--render-surfaces`.
    private(set) var lastRequest: HUDRequest?
    /// A card is up, so a card that can wait should.
    var isShowing: Bool { shownID != nil }

    static let width: CGFloat = 420
    static let inset: CGFloat = 14

    @discardableResult
    func present(_ request: HUDRequest) -> Bool {
        lastRequest = request
        if RenderSurfaces.isActive { return true }
        let panel = panel ?? makePanel()
        self.panel = panel
        let card = HUDCardView(content: request.content)
        let hosting = NSHostingView(rootView: card)
        hosting.sizingOptions = []
        let size = Self.size(of: request)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return false }
        let visible = screen.visibleFrame
        let end = NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 8,
                         width: size.width, height: size.height)
        let wasShowing = panel.isVisible && shownID != nil
        shownID = request.id

        if wasShowing || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(end, display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            panel.setFrame(end.offsetBy(dx: 0, dy: 12), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(end, display: true)
                panel.animator().alphaValue = 1
            }
        }

        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: request.accessibilityLabel,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])

        scheduleDismiss(id: request.id, after: request.duration)
        return true
    }

    /// The card at its width, as tall as its content is now. Measured on a
    /// second view: with no sizing options the one on screen has no fitting
    /// size, and the card would open 0 by 0.
    private static func size(of request: HUDRequest) -> NSSize {
        let probe = NSHostingView(rootView: HUDCardView(content: request.content))
        probe.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        return NSSize(width: width, height: ceil(probe.fittingSize.height))
    }

    /// A card is measured when it comes up, and stays that size. One whose
    /// content gains a row (the finish card, once answered, making room for
    /// the next step) asks to be measured again: it keeps its top edge and
    /// grows down. Does nothing if another card has taken its place.
    func remeasure(id: String) {
        guard isShowing(id: id), let panel, let request = lastRequest, request.id == id else { return }
        let size = Self.size(of: request)
        guard abs(size.height - panel.frame.height) > 0.5 else { return }
        let frame = NSRect(x: panel.frame.midX - size.width / 2, y: panel.frame.maxY - size.height,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Lets a card's text field take typing, without making Nidus the active
    /// app. Only for something the person asked for (a menu item): a card
    /// never takes the keyboard on its own.
    func makeKey(id: String) {
        guard isShowing(id: id) else { return }
        panel?.makeKey()
    }

    func dismiss(id: String) {
        guard shownID == id else { return }
        hide()
    }

    /// Whether this card is the one on screen now: not replaced, not gone.
    func isShowing(id: String) -> Bool {
        shownID == id && panel?.isVisible == true
    }

    /// Gives the card showing a fresh `seconds` before it goes, and says why
    /// to VoiceOver. For a card that has just changed in place (an answer
    /// confirmed) so the new words can be read. Does nothing, and says so, if
    /// another card has taken its place or it has gone.
    @discardableResult
    func refresh(id: String, duration seconds: TimeInterval, announcing announcement: String? = nil) -> Bool {
        guard isShowing(id: id) else { return false }
        scheduleDismiss(id: id, after: seconds)
        if let announcement {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
        return true
    }

    private func scheduleDismiss(id: String, after seconds: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            // Kept while the pointer rests on it, so a button can be reached,
            // and while it holds the keyboard, so a sentence can be finished.
            while !Task.isCancelled, let panel = self?.panel, panel.frame.contains(NSEvent.mouseLocation) || panel.isKeyWindow {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            self?.dismiss(id: id)
        }
    }

    private func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        shownID = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A card that came in while this one faded stays.
                if self?.shownID == nil { self?.panel?.orderOut(nil) }
            }
        }
    }

    private func makePanel() -> CardPanel {
        let panel = CardPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: true)
        // After isFloatingPanel, which sets its own level.
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }
}

/// Takes clicks without making Nidus the active app.
private final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct HUDCardView: View {
    let content: AnyView

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, HUDPresenter.inset + 4)
            .padding(.vertical, HUDPresenter.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Liquid Glass, as the Mac's own notifications.
            .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
    }
}
