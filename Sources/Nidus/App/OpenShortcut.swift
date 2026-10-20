//
//  OpenShortcut.swift
//  Nidus
//
//  The Open Nidus shortcut: a global key that opens the menu bar popover from
//  any app, and puts it away when pressed again. Off until it is set, in
//  Settings, General. It is the capture shortcut's machinery (KeyShortcut,
//  HotKeyRegistrar, the recorder) with a registrar of its own, and the two
//  can't be the same keys: the recorder refuses a combination the other has.
//
//  Opening the popover is what clicking the menu bar icon does, so with no
//  session running it lands in the goal field, ready to type. A running
//  session shows its own controls; there is nothing to type into.
//

import AppKit
import SwiftUI

extension NidusModel.Key {
    /// The Open Nidus shortcut, a `KeyShortcut`; absent or null is off.
    static let openShortcut = "openShortcut"
}

/// The Open Nidus shortcut and its registration. One, held by the model.
@MainActor
final class OpenShortcutCoordinator {
    private let shortcut: GlobalShortcut

    /// `registrar` is the system's hot key in the app and a fake in tests.
    init(registrar: HotKeyRegistrar = CarbonHotKeyRegistrar(id: 2), onPress: @escaping @MainActor () -> Void) {
        shortcut = GlobalShortcut(registrar: registrar, onPress: onPress)
    }

    var current: KeyShortcut? { shortcut.current }
    /// The system refused the shortcut asked for (another app has it).
    var isRefused: Bool { shortcut.isRefused }

    /// A demo or a render has no business with the person's real hot keys,
    /// and registers none.
    @discardableResult
    func apply(_ new: KeyShortcut?) -> Bool {
        guard !Demo.isActive else { return false }
        return shortcut.apply(new)
    }

    func stop() { shortcut.stop() }
}

extension NidusModel {
    /// The global shortcut that opens (and closes) the popover. Off until set.
    /// A combination the capture shortcut has is not taken.
    var openShortcut: KeyShortcut? {
        get { preference(Key.openShortcut, default: KeyShortcut?.none) }
        set {
            if let newValue, shortcutConflict(newValue, for: .openNidus) != nil { return }
            setPreference(newValue, Key.openShortcut)
            openHotKey.apply(newValue)
            objectWillChange.send()
        }
    }

    /// Why `shortcut` can't be used for `purpose`: the other Nidus shortcut
    /// has it. nil when it can.
    func shortcutConflict(_ shortcut: KeyShortcut, for purpose: ShortcutPurpose) -> String? {
        ShortcutConflict.message(for: shortcut, purpose: purpose, capture: captureShortcut, openNidus: openShortcut)
    }

    /// The shortcut was pressed: the popover opens, or closes if it is open.
    func togglePopoverFromShortcut() {
        menuBarItem?.togglePopover()
    }

    /// Registers the saved shortcut, if there is one. Called from `activate`.
    func startOpenShortcut() {
        openHotKey.apply(openShortcut)
    }

    /// Lets go of the shortcut. Called from `deactivate`.
    func stopOpenShortcut() {
        openHotKey.stop()
    }
}

/// The row in General's Menu bar and login card.
struct OpenNidusShortcutRows: View {
    @ObservedObject var model: NidusModel

    var body: some View {
        NidusControlRow(title: "Open Nidus",
                          infoTip: "Opens Nidus from any app, ready to type a goal. Press it again to put it away. Off until you set one.") {
            ShortcutRecorder(shortcut: model.binding(\.openShortcut), name: "Open Nidus shortcut",
                             conflict: { model.shortcutConflict($0, for: .openNidus) })
        }
        if model.openShortcut != nil, model.openHotKey.isRefused {
            Label("Another app is using that combination. Choose a different one.",
                  systemImage: "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }
}
