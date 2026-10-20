//
//  OpenShortcutTests.swift
//  NidusTests
//
//  The Open Nidus shortcut: off until set, registered through its own
//  registrar, pressing it runs the toggle, and it can never be the capture
//  shortcut's keys. Only fakes register anything; no real hot key is touched.
//

import AppKit
import Foundation
import Testing
@testable import Nidus

@MainActor
private final class FakeOpenRegistrar: HotKeyRegistrar {
    var registered: [KeyShortcut] = []
    var accepts = true
    var handler: (@MainActor () -> Void)?

    func register(_ shortcut: KeyShortcut, handler: @escaping @MainActor () -> Void) -> Bool {
        guard accepts else { return false }
        registered.append(shortcut)
        self.handler = handler
        return true
    }

    func unregister() { handler = nil }
    var isLive: Bool { handler != nil }
}

@MainActor
struct OpenShortcutTests {
    private let open = KeyShortcut(keyCode: 45, modifiers: [.control, .option], key: "N")!
    private let capture = KeyShortcut(keyCode: 49, modifiers: [.control, .option], key: "Space")!

    // MARK: Registering

    @Test func itIsOffUntilItIsSet() {
        let registrar = FakeOpenRegistrar()
        let coordinator = OpenShortcutCoordinator(registrar: registrar) {}
        #expect(coordinator.current == nil)
        #expect(!coordinator.isRefused)
        #expect(!registrar.isLive, "nothing is registered until a shortcut is set")
    }

    @Test func settingItRegistersItAndPressingItRunsTheToggle() {
        let registrar = FakeOpenRegistrar()
        var presses = 0
        let coordinator = OpenShortcutCoordinator(registrar: registrar) { presses += 1 }
        #expect(coordinator.apply(open))
        #expect(registrar.registered == [open])
        registrar.handler?()
        registrar.handler?()
        #expect(presses == 2, "every press runs the toggle; the popover decides open or close")
    }

    @Test func replacingAndClearingLetGoOfTheOldKeys() {
        let registrar = FakeOpenRegistrar()
        let coordinator = OpenShortcutCoordinator(registrar: registrar) {}
        coordinator.apply(open)
        coordinator.apply(capture)
        #expect(registrar.registered == [open, capture])
        #expect(coordinator.current == capture)
        coordinator.apply(nil)
        #expect(!registrar.isLive)
        #expect(coordinator.current == nil)
    }

    @Test func stoppingLetsGo() {
        let registrar = FakeOpenRegistrar()
        let coordinator = OpenShortcutCoordinator(registrar: registrar) {}
        coordinator.apply(open)
        coordinator.stop()
        #expect(!registrar.isLive)
        #expect(coordinator.current == nil)
    }

    @Test func aCombinationTheSystemRefusesIsSaidSo() {
        let registrar = FakeOpenRegistrar()
        registrar.accepts = false
        let coordinator = OpenShortcutCoordinator(registrar: registrar) {}
        #expect(!coordinator.apply(open))
        #expect(coordinator.isRefused)
        #expect(coordinator.current == open, "what was asked for is still shown, with the problem")
    }

    @Test func itAndTheCaptureShortcutAreRegisteredApart() {
        // Two registrars, one each: pressing one key runs only its own action.
        let openRegistrar = FakeOpenRegistrar()
        let captureRegistrar = FakeOpenRegistrar()
        var opened = 0, captured = 0
        let coordinator = OpenShortcutCoordinator(registrar: openRegistrar) { opened += 1 }
        let captureShortcut = CaptureShortcut(registrar: captureRegistrar) { captured += 1 }
        coordinator.apply(open)
        captureShortcut.apply(capture)
        openRegistrar.handler?()
        #expect(opened == 1 && captured == 0)
        captureRegistrar.handler?()
        #expect(opened == 1 && captured == 1)
        captureShortcut.apply(nil)
        #expect(openRegistrar.isLive, "clearing capture leaves Open Nidus registered")
    }

    @Test func eachShortcutKeepsItsOwnHotKeyID() {
        #expect(CarbonHotKeyRegistrar().id == 1, "the capture shortcut's id is the one it always had")
        #expect(CarbonHotKeyRegistrar(id: 2).id == 2)
    }

    // MARK: Never the same keys

    @Test func theCaptureKeysAreNotTakenForOpenNidus() {
        let message = ShortcutConflict.message(for: capture, purpose: .openNidus, capture: capture, openNidus: nil)
        #expect(message != nil)
        #expect(message?.contains("capture") == true)
        #expect(message?.contains(capture.display) == true, "it says which keys")
        #expect(message?.contains("different") == true, "and what to do")
    }

    @Test func theOpenKeysAreNotTakenForCapture() {
        let message = ShortcutConflict.message(for: open, purpose: .capture, capture: nil, openNidus: open)
        #expect(message?.contains("Open Nidus") == true)
    }

    @Test func anythingElseIsFree() {
        // Not the other's keys, including the same key with other modifiers.
        let nearly = KeyShortcut(keyCode: 45, modifiers: [.control, .option, .shift], key: "N")!
        #expect(ShortcutConflict.message(for: nearly, purpose: .capture, capture: nil, openNidus: open) == nil)
        #expect(ShortcutConflict.message(for: open, purpose: .openNidus, capture: capture, openNidus: nil) == nil)
        #expect(ShortcutConflict.message(for: capture, purpose: .capture, capture: capture, openNidus: nil) == nil,
                "a shortcut can be set again to itself")
        #expect(ShortcutConflict.message(for: open, purpose: .openNidus, capture: nil, openNidus: nil) == nil)
    }

    @Test func theRecorderRefusesTheOtherShortcutsKeysAndKeepsListening() throws {
        let recording = ShortcutRecording()
        var chosen: [KeyShortcut?] = []
        recording.start(conflict: { [capture] in
            ShortcutConflict.message(for: $0, purpose: .openNidus, capture: capture, openNidus: nil)
        }) { chosen.append($0) }
        defer { recording.stop() }

        func press(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                          windowNumber: 0, context: nil, characters: characters,
                                          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        }
        recording.read(try press(49, " ", [.control, .option]), { chosen.append($0) })
        #expect(chosen.isEmpty, "the capture keys are not taken")
        #expect(recording.isRecording, "it keeps listening for another")
        #expect(recording.note?.contains("capture") == true, "and says why")

        recording.read(try press(45, "n", [.control, .option]), { chosen.append($0) })
        #expect(chosen == [open])
        #expect(!recording.isRecording)
        #expect(recording.note == nil)
    }

    // MARK: The model

    @Test func withoutAHostThereIsNoOpenShortcutAndNothingConflicts() {
        let model = NidusModel()
        #expect(model.openShortcut == nil)
        #expect(model.shortcutConflict(open, for: .openNidus) == nil)
        #expect(model.shortcutConflict(capture, for: .capture) == nil)
        #expect(!model.openHotKey.isRefused)
        #expect(model.openHotKey.current == nil)
    }

    @Test func pressingItWithNoPopoverDoesNothing() {
        // No menu bar item until the model is activated: nothing to toggle,
        // and nothing breaks.
        NidusModel().togglePopoverFromShortcut()
    }

    @Test func itIsStoredApartFromTheCaptureShortcut() {
        #expect(NidusModel.Key.openShortcut != NidusModel.Key.captureShortcut)
    }
}
