//
//  FocusCapture.swift
//  Nidus
//
//  Quick capture: a small panel for a thought or a link, opened by a global
//  shortcut (off until the person sets one) or by "Save a thought" in the
//  popover. It takes the keyboard without making Nidus the active app, so the
//  app you were in stays in front and gets the keyboard back the moment the
//  panel goes. Saving puts the words in the inbox (Core/FocusInbox.swift) and
//  never changes the session.
//
//  The shortcut is a Carbon hot key: macOS tells Nidus when that one
//  combination is pressed and about no other key, with no Input Monitoring or
//  Accessibility permission. It sits behind HotKeyRegistrar so tests register
//  nothing.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - The hot key

/// Registers one global hot key with Carbon. Used only by the app: tests and
/// renders use a fake, or none.
@MainActor
final class CarbonHotKeyRegistrar: HotKeyRegistrar {
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var action: (@MainActor () -> Void)?

    /// 'NDUS'. Only this app's hot keys are sent here, but the system wants one.
    private static let signature: OSType = 0x4E44_5553

    func register(_ shortcut: KeyShortcut, handler: @escaping @MainActor () -> Void) -> Bool {
        unregister()
        action = handler
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let registrar = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
            // Application events arrive on the main thread.
            MainActor.assumeIsolated { registrar.action?() }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard installed == noErr else {
            unregister()
            return false
        }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let registered = RegisterEventHotKey(UInt32(shortcut.keyCode), Self.carbonModifiers(shortcut.modifiers), id,
                                             GetApplicationEventTarget(), 0, &hotKey)
        guard registered == noErr else {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        action = nil
    }

    static func carbonModifiers(_ modifiers: KeyShortcut.Modifiers) -> UInt32 {
        var result = 0
        if modifiers.contains(.command) { result |= cmdKey }
        if modifiers.contains(.control) { result |= controlKey }
        if modifiers.contains(.option) { result |= optionKey }
        if modifiers.contains(.shift) { result |= shiftKey }
        return UInt32(result)
    }
}

// MARK: - The panel

/// What is typed into the panel, kept while it closes and opens: a click
/// elsewhere closes the panel, and it shouldn't take a half-typed thought
/// with it. Cleared by a save.
@MainActor @Observable
final class CaptureDraft {
    var text = ""
    var link = ""
    /// Why the last Save added nothing, in a few words.
    var note: String?

    var isEmpty: Bool { text.isEmpty && link.isEmpty }

    func clear() {
        text = ""
        link = ""
        note = nil
    }
}

/// Takes the keyboard without making Nidus the active app.
private final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The capture panel and the global shortcut that opens it. One of each,
/// held by the model.
@MainActor
final class CaptureCoordinator {
    let draft = CaptureDraft()
    private var panel: CapturePanel?
    private var resignObserver: NSObjectProtocol?
    private weak var model: NidusModel?
    /// The shortcut opens the panel, and pressing it again puts it away.
    private lazy var shortcut = CaptureShortcut(registrar: CarbonHotKeyRegistrar()) { [weak self] in
        guard let self else { return }
        if isShowing { hide() } else { model?.showCapturePanel() }
    }

    static let width: CGFloat = 420

    /// The shortcut asked for was refused by the system.
    var shortcutIsRefused: Bool { shortcut.isRefused }

    /// Registers the saved shortcut, if there is one. A demo or a render has
    /// no business with the person's real hot keys, and registers none.
    func start(model: NidusModel) {
        self.model = model
        apply(model.captureShortcut)
    }

    func apply(_ new: KeyShortcut?) {
        guard !Demo.isActive else { return }
        shortcut.apply(new)
    }

    func stop() {
        hide()
        shortcut.stop()
        model = nil
    }

    var isShowing: Bool { panel?.isVisible == true }

    func show(model: NidusModel) {
        self.model = model
        // A render or a capture draws the view itself; no panel opens on the
        // person's screen.
        guard !RenderSurfaces.isActive, !CaptureSurfaces.isActive else { return }
        draft.note = nil
        let panel = panel ?? makePanel()
        self.panel = panel
        let view = FocusCaptureView(draft: draft,
                                    save: { [weak self] in self?.save() },
                                    cancel: { [weak self] in self?.hide() })
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        // Measured on a second view: with no sizing options this one has no
        // fitting size.
        let probe = NSHostingView(rootView: view)
        probe.frame = NSRect(x: 0, y: 0, width: Self.width, height: 10)
        let size = NSSize(width: Self.width, height: ceil(probe.fittingSize.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting

        // On the screen the pointer is on, a little above the middle.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.midX - size.width / 2,
                              y: visible.minY + visible.height * 0.6 - size.height / 2,
                              width: size.width, height: size.height), display: true)
        // Key without activating: the app you were in stays the active one.
        panel.makeKeyAndOrderFront(nil)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: "Save for later. Type a thought, then press Return.",
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Return in either field, or the Save button.
    func save() {
        guard let model else { return }
        switch model.saveToInbox(text: draft.text, link: draft.link) {
        case .added(_, let droppedLink):
            // The words went in; only the address was not one Nidus keeps.
            // Nothing else to say: the panel goes and the draft with it.
            _ = droppedLink
            draft.clear()
            hide()
        case .duplicate:
            draft.note = "That link is already in your inbox."
        case .empty:
            draft.note = "Type a thought or paste a link."
        }
    }

    private func makePanel() -> CapturePanel {
        let panel = CapturePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: true)
        // After isFloatingPanel, which sets its own level.
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        // Clicking another app's window puts the panel away; the draft stays.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        return panel
    }
}

// MARK: - The panel's content

/// Two fields and two buttons. Return saves, Escape cancels. Saving adds to
/// the inbox and nothing else: the session, strict or not, is not touched.
struct FocusCaptureView: View {
    @Bindable var draft: CaptureDraft
    let save: () -> Void
    let cancel: () -> Void

    private enum Field { case text, link }
    @FocusState private var focused: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: NidusSpacing.md) {
            HStack(spacing: NidusSpacing.md) {
                SettingsTile(symbol: "tray.and.arrow.down", size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save for later")
                        .font(.system(size: 14, weight: .medium))
                    Text("It goes in your inbox. Your session carries on.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: NidusSpacing.sm) {
                TextField("What's on your mind?", text: $draft.text)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($focused, equals: .text)
                    .onSubmit(save)
                    .onChange(of: draft.text) { _, text in
                        // The limit is the inbox's; the field stops at it.
                        if text.count > FocusInbox.textLimit { draft.text = String(text.prefix(FocusInbox.textLimit)) }
                        draft.note = nil
                    }
                    .accessibilityLabel("Thought")
                TextField("Link (optional)", text: $draft.link)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($focused, equals: .link)
                    .onSubmit(save)
                    .onChange(of: draft.link) { _, _ in draft.note = nil }
                    .accessibilityLabel("Link, optional")
            }
            HStack(spacing: NidusSpacing.sm) {
                footnote
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: NidusSpacing.sm)
                Button("Cancel", action: cancel)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .fixedSize()
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .tint(FocusPalette.clay)
                    .keyboardShortcut(.defaultAction)
                    .fixedSize()
                    .disabled(!canSave)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, HUDPresenter.inset + 4)
        .padding(.vertical, HUDPresenter.inset + 2)
        .frame(width: CaptureCoordinator.width)
        // Liquid Glass, as the cards.
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .onExitCommand(perform: cancel)
        .onAppear { DispatchQueue.main.async { focused = .text } }
    }

    /// The link is not one Nidus keeps (only http and https are): said before
    /// saving, so it isn't a surprise afterwards.
    private var linkIsRefused: Bool {
        !draft.link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && InboxURL.clean(draft.link, assumingHTTPS: true) == nil
    }

    private var canSave: Bool {
        !InboxText.clean(draft.text).isEmpty || InboxURL.clean(draft.link, assumingHTTPS: true) != nil
    }

    @ViewBuilder
    private var footnote: some View {
        if let note = draft.note {
            Text(verbatim: note)
        } else if linkIsRefused {
            Label {
                Text("Only web links are kept.")
            } icon: {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            }
        } else if draft.text.count > FocusInbox.textLimit - 40 {
            Text(verbatim: "\(draft.text.count) of \(FocusInbox.textLimit)")
        } else {
            Text("Return saves \u{00B7} Esc cancels")
        }
    }
}

// MARK: - Recording a shortcut

/// A button that records the next key combination, as System Settings' own
/// shortcut recorders do. While it is recording, a local monitor (this app's
/// own key events only) reads one key; Escape cancels, Delete clears. A key
/// held with none of ⌘, ⌃ or ⌥ is refused, because the shortcut would then
/// take that key from every app.
struct ShortcutRecorder: View {
    @Binding var shortcut: KeyShortcut?
    @State private var recorder = ShortcutRecording()

    var body: some View {
        HStack(spacing: NidusSpacing.sm) {
            Button {
                recorder.isRecording ? recorder.stop() : recorder.start { shortcut = $0 }
            } label: {
                Text(verbatim: label)
                    .frame(minWidth: 130)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(recorder.isRecording ? "Recording. Press the shortcut you want."
                                : "Capture shortcut: \(shortcut?.spoken ?? "none")")
            .accessibilityHint(recorder.isRecording ? "Press Escape to cancel." : "Press to record a new shortcut.")
            if shortcut != nil, !recorder.isRecording {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Turn the shortcut off")
                .accessibilityLabel("Turn the capture shortcut off")
            }
        }
        .onDisappear { recorder.stop() }
    }

    private var label: String {
        if recorder.isRecording { return recorder.hint ?? "Type shortcut\u{2026}" }
        return shortcut?.display ?? "Record Shortcut"
    }
}

@MainActor @Observable
final class ShortcutRecording {
    private(set) var isRecording = false
    /// Said on the button when the last key was not usable.
    private(set) var hint: String?
    @ObservationIgnored private var monitor: Any?

    func start(_ chosen: @escaping (KeyShortcut?) -> Void) {
        stop()
        isRecording = true
        hint = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.read(event, chosen)
            }
            // Every key is ours while recording, so none beeps or types.
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        hint = nil
    }

    private func read(_ event: NSEvent, _ chosen: (KeyShortcut?) -> Void) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: KeyShortcut.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if event.keyCode == 53, modifiers.isEmpty { return stop() }
        if event.keyCode == 51, modifiers.isEmpty {
            chosen(nil)
            return stop()
        }
        guard let name = KeyShortcut.name(forKeyCode: event.keyCode, characters: event.charactersIgnoringModifiers),
              let shortcut = KeyShortcut(keyCode: event.keyCode, modifiers: modifiers, key: name) else {
            hint = "Hold \u{2318}, \u{2303} or \u{2325}"
            return
        }
        chosen(shortcut)
        stop()
    }
}
