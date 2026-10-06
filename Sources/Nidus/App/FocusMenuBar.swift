//
//  FocusMenuBar.swift
//  Nidus
//
//  The menu bar item, Nidus's home: the glyph animates from particle to
//  brain when a session starts, fills as it runs, and comes back when it
//  ends. A click opens the popover (set up, start, pause, end); a right-click
//  or Control-click opens a short menu. Created in activate(host:), removed
//  in deactivate().
//
//  The time left can show beside it, as a setting. The digits are the
//  button's own title, so AppKit draws them in the menu bar's font, colour
//  and highlight, on the clock's baseline. The glyph sits over a blank image
//  of its size, in the rect AppKit gives that image.
//

import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class FocusMenuBar: NSObject, NSMenuDelegate {
    private weak var model: NidusModel?
    private var item: NSStatusItem?
    private var glyph: FocusGlyphView?
    /// True while a start or end sequence is playing; clock ticks wait.
    private var isTransitioning = false
    private var frameObserver: NSObjectProtocol?
    private var popover: NSPopover?
    private let menu = NSMenu()

    static let glyphSize: CGFloat = 18
    /// Holds the glyph's place, so the title lays out beside it.
    private static let placeholder: NSImage = {
        let image = NSImage(size: NSSize(width: glyphSize, height: glyphSize))
        image.isTemplate = true
        return image
    }()

    init(model: NidusModel) {
        self.model = model
    }

    // MARK: Lifecycle

    func start() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "nidus"
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.image = Self.placeholder
            button.imagePosition = .imageOnly
            button.toolTip = "Nidus"
            button.setAccessibilityLabel("Nidus")
            let glyph = FocusGlyphView(size: Self.glyphSize)
            button.addSubview(glyph)
            glyph.show(steadyState(), duration: 0)
            self.glyph = glyph
            // The button resizes when the title comes and goes; the glyph
            // follows its image rect.
            button.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: button, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeGlyph() }
            }
        }
        menu.delegate = self
        self.item = item
        updateTime()
        placeGlyph()
    }

    func stop() {
        popover?.close()
        popover = nil
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
        glyph = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    // MARK: Session events

    func sessionDidStart() {
        updateTime()
        guard let glyph else { return }
        if reducesMotion { return glyph.show(steadyState(), duration: 0.2) }
        var morphed = GlyphState.brain
        morphed.detail = 0
        isTransitioning = true
        glyph.play([(morphed, 0.85), (steadyState(), 0.35)]) { [weak self] in
            self?.isTransitioning = false
            self?.sync()
        }
    }

    func sessionDidEnd(completed: Bool) {
        updateTime()
        guard let glyph else { return }
        if reducesMotion { return glyph.show(.particle, duration: 0.2) }
        var steps: [(GlyphState, CFTimeInterval)] = []
        var s = glyph.state
        s.alpha = 1
        s.offsetX = 0
        if completed {
            s.fill = 1
            steps.append((s, 0.4))
            var pop = s
            pop.scale = 1.1
            steps.append((pop, 0.18))
            steps.append((s, 0.22))
        }
        s.detail = 0
        s.fill = 0
        steps.append((s, 0.3))
        steps.append((.particle, 0.8))
        isTransitioning = true
        glyph.play(steps) { [weak self] in
            self?.isTransitioning = false
            self?.sync()
        }
    }

    /// A tick of the clock, a pause or a resume: glide to what the glyph
    /// should show now. The fill moves over the whole second, linearly, so it
    /// rises continuously rather than in steps.
    func sync() {
        updateTime()
        guard let glyph, !isTransitioning else { return }
        let target = steadyState()
        guard target != glyph.state else { return }
        if reducesMotion { return glyph.show(target, duration: 0) }
        if target.alpha != glyph.state.alpha || target.morph != glyph.state.morph {
            glyph.show(target, duration: 0.3)
        } else {
            glyph.show(target, duration: 1, timing: CAMediaTimingFunction(name: .linear))
        }
    }

    /// Something was just blocked: the brain flinches once.
    func flinch() {
        guard let glyph, !isTransitioning, glyph.state.morph >= 1, !reducesMotion else { return }
        glyph.flinch()
    }

    // MARK: Time left

    /// Shows or updates the time beside the glyph, or takes it away: only
    /// while a session runs, and only when the setting is on.
    private func updateTime() {
        guard let item, let button = item.button, let model else { return }
        let text = model.menuBarShowsTime && (model.isActive || model.isOnBreak) ? model.clockText : ""
        if text.isEmpty {
            guard button.imagePosition != .imageOnly else { return }
            button.attributedTitle = NSAttributedString()
            button.imagePosition = .imageOnly
            item.length = NSStatusItem.squareLength
            button.setAccessibilityValue(nil)
        } else {
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            // Paused, the digits dim with the brain; a break's are quiet too.
            if model.isPaused || model.isOnBreak { attributes[.foregroundColor] = NSColor.secondaryLabelColor }
            let title = NSAttributedString(string: text, attributes: attributes)
            guard button.attributedTitle != title || button.imagePosition != .imageLeading else { return }
            button.attributedTitle = title
            button.imagePosition = .imageLeading
            item.length = NSStatusItem.variableLength
            button.setAccessibilityValue(model.isOnBreak ? "\(text) of break left"
                                         : model.isOpenEnded ? "\(text) focused" : "\(text) left")
        }
        placeGlyph()
    }

    /// Puts the glyph where AppKit put the blank image it stands in for.
    private func placeGlyph() {
        guard let button = item?.button, let glyph else { return }
        let rect = button.cell?.imageRect(forBounds: button.bounds) ?? button.bounds
        let size = Self.glyphSize
        let frame = NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size)
        if glyph.frame != frame { glyph.frame = frame }
    }

    // MARK: Glyph state

    /// What the glyph shows when nothing is animating.
    private func steadyState() -> GlyphState {
        guard let model, model.isActive else { return .particle }
        var s = GlyphState.brain
        s.fill = model.isOpenEnded ? 0 : model.progress
        s.alpha = model.isPaused ? 0.4 : 1
        return s
    }

    private var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: Popover

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        if let popover, popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let model, let button = item?.button else { return }
        let popover = popover ?? {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            let hosting = NSHostingController(rootView: NidusPopover(model: model))
            // Idle and running differ in height; the popover follows.
            hosting.sizingOptions = [.preferredContentSize]
            popover.contentViewController = hosting
            return popover
        }()
        self.popover = popover
        // A menu bar app is not active until it is asked to be; without this
        // the goal field shows a caret but takes no typing.
        if !CaptureSurfaces.isActive { NSApp.activate() }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// The popover's window, for `--capture-surfaces`.
    var popoverWindowNumber: Int? { popover?.contentViewController?.view.window?.windowNumber }

    func closePopover() {
        popover?.performClose(nil)
    }

    private func showMenu() {
        guard let item, let button = item.button else { return }
        popover?.performClose(nil)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model else { return }
        if model.isActive {
            let header = NSMenuItem()
            header.view = NSHostingView(rootView: FocusMenuHeader(model: model))
            menu.addItem(header)
            menu.addItem(.separator())
            if !model.isStrict {
                menu.addItem(action(model.isPaused ? "Resume" : "Pause", #selector(togglePause)))
            }
            if !model.isOpenEnded {
                menu.addItem(action("Add 5 minutes", #selector(addTime)))
            }
            menu.addItem(.separator())
            if model.isStrict {
                // Ending early takes the phrase, which only the popover asks for.
                let note = NSMenuItem(title: "Strict: end early from the popover", action: nil, keyEquivalent: "")
                note.isEnabled = false
                menu.addItem(note)
            } else {
                menu.addItem(action("End session", #selector(endSession)))
            }
        } else if model.isOnBreak {
            let header = NSMenuItem()
            header.view = NSHostingView(rootView: FocusMenuHeader(model: model))
            menu.addItem(header)
            menu.addItem(.separator())
            menu.addItem(action("Start next session now", #selector(skipBreak)))
            menu.addItem(action("End break", #selector(endBreak)))
        } else {
            if let pending = model.pendingFinish {
                // Asked on the wrap-up card too; here until answered or the
                // next session starts.
                let ask = NSMenuItem(title: "Did you finish \u{201C}\(pending.goal)\u{201D}?", action: nil, keyEquivalent: "")
                ask.isEnabled = false
                menu.addItem(ask)
                menu.addItem(action("Yes, finished", #selector(answeredYes)))
                menu.addItem(action("Not yet", #selector(answeredNo)))
                menu.addItem(.separator())
            }
            let start = action("Start focus", #selector(startSession))
            let setups = model.setupMenuItems()
            // With setups listed beside it, Start focus takes an icon too,
            // so the group's titles line up.
            if !setups.isEmpty { start.image = FocusSetupsMenu.symbolImage("play") }
            let plan = "\(FocusFormat.duration(minutes: model.durationMinutes)) · \(model.selectionSummary)"
            if #available(macOS 14.4, *) {
                start.subtitle = plan
                menu.addItem(start)
            } else {
                menu.addItem(start)
                let detail = NSMenuItem(title: plan, action: nil, keyEquivalent: "")
                detail.isEnabled = false
                menu.addItem(detail)
            }
            setups.forEach(menu.addItem)
            menu.addItem(.separator())
            menu.addItem(action("Stats…", #selector(openStats)))
            menu.addItem(action("Nidus settings…", #selector(openSettings)))
        }
        // Quitting would end a strict session, so it waits for the end.
        if !model.isStrict {
            menu.addItem(.separator())
            menu.addItem(action("Quit Nidus", #selector(quit)))
        }
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func startSession() { model?.startSession() }
    @objc private func togglePause() { model?.togglePause() }
    @objc private func addTime() { model?.addTime() }
    @objc private func endSession() { model?.endSession() }
    @objc private func skipBreak() { model?.skipBreak() }
    @objc private func answeredYes() { model?.answerFinished(true) }
    @objc private func answeredNo() { model?.answerFinished(false) }
    @objc private func endBreak() { model?.endBreak() }
    @objc private func openSettings() { model?.openSettings() }
    @objc private func openStats() { model?.openStats() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// The running session at the top of the menu: goal, countdown, progress.
/// It ticks while the menu is open because the model publishes every second
/// of a session.
struct FocusMenuHeader: View {
    @ObservedObject var model: NidusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Text(verbatim: model.clockText)
                .font(.system(size: 28, weight: .light))
                .monospacedDigit()
                .foregroundStyle(model.isPaused || model.isOnBreak ? .secondary : .primary)
            if model.isOnBreak || !model.isOpenEnded {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(model.isPaused || model.isOnBreak ? AnyShapeStyle(.tertiary) : AnyShapeStyle(FocusPalette.clay))
                            .frame(width: max(3, proxy.size.width * (model.isOnBreak ? model.breakProgress : model.progress)))
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: 240, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if model.isOnBreak { return model.nextGoal.isEmpty ? "Break" : "Break, then \(model.nextGoal)" }
        return model.goal.isEmpty ? (model.isPaused ? "Paused" : "Focusing") : model.goal
    }
}
