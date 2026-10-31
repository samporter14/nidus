//
//  FocusFilterTests.swift
//  NidusTests
//
//  The Focus filter (FocusFilter.swift): when it starts and ends a session,
//  the remembered start, and the loop a Focus and a Shortcut could make,
//  against a fake session. Whether macOS calls the intent when a Focus turns
//  on or off is up to the system, and not tested here.
//

import Foundation
import Testing
@testable import Nidus

/// The fake session, plus the start time the filter remembers.
@MainActor
final class FakeFilterTarget: FocusFilterTarget {
    let inner = FakeFocusTarget()
    var sessionStartedAt: Date?
    private var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)

    var commandStatus: FocusStatus { inner.commandStatus }
    var setups: [FocusSetup] { get { inner.setups } set { inner.setups = newValue } }
    var categories: [FocusCategory] { inner.categories }

    func startFromOutside(_ request: SessionRequest) -> OutsideStart {
        let result = inner.startFromOutside(request)
        if result == .started { clock.addTimeInterval(60); sessionStartedAt = clock }
        return result
    }

    func endFromOutside() -> OutsideEnd {
        let result = inner.endFromOutside()
        if result == .endsSession { sessionStartedAt = nil }
        return result
    }

    func extendSession(by seconds: TimeInterval) { inner.extendSession(by: seconds) }

    /// The user starts a session by hand, at a time of their own.
    func startByHand(at date: Date, strict: Bool = false) {
        inner.state = .running
        inner.isStrict = strict
        sessionStartedAt = date
    }
}

private func freshDefaults() -> (UserDefaults, String) {
    let name = "local.sam.nidus.tests.focusfilter.\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}

// MARK: - Decisions

struct FocusFilterDecisionTests {
    private let t = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func activationStartsOnlyIntoSilence() {
        #expect(FocusFilterDecision.onActivate(sessionRunning: false, onBreak: false) == .start)
        #expect(FocusFilterDecision.onActivate(sessionRunning: true, onBreak: false) == .ignore)
        #expect(FocusFilterDecision.onActivate(sessionRunning: false, onBreak: true) == .ignore)
        #expect(FocusFilterDecision.onActivate(sessionRunning: true, onBreak: true) == .ignore)
    }

    @Test func deactivationEndsOnlyTheSameNonStrictSession() {
        #expect(FocusFilterDecision.onDeactivate(currentStartedAt: t, currentStrict: false, storedStartedAt: t) == .end)
        #expect(FocusFilterDecision.onDeactivate(currentStartedAt: t, currentStrict: true, storedStartedAt: t) == .leave)
        #expect(FocusFilterDecision.onDeactivate(currentStartedAt: t.addingTimeInterval(1), currentStrict: false, storedStartedAt: t) == .leave)
        #expect(FocusFilterDecision.onDeactivate(currentStartedAt: nil, currentStrict: false, storedStartedAt: t) == .leave)
        #expect(FocusFilterDecision.onDeactivate(currentStartedAt: t, currentStrict: false, storedStartedAt: nil) == .leave)
        #expect(FocusFilterDecision.onDeactivate(currentStartedAt: nil, currentStrict: false, storedStartedAt: nil) == .leave)
    }
}

// MARK: - The remembered start

struct FocusFilterMarkerTests {
    @Test func theStartTimeRoundTripsExactly() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let marker = FocusFilterMarker(defaults: defaults)
        #expect(marker.startedAt == nil)
        let date = Date(timeIntervalSinceReferenceDate: 801_234_567.891_234)
        marker.startedAt = date
        // A second reader, as after a relaunch.
        #expect(FocusFilterMarker(defaults: defaults).startedAt == date)
        marker.startedAt = nil
        #expect(FocusFilterMarker(defaults: defaults).startedAt == nil)
        #expect(defaults.object(forKey: FocusFilterMarker.key) == nil)
    }
}

// MARK: - Turning a Focus on and off

@MainActor
struct FocusFilterRunTests {
    private func rig() -> (FakeFilterTarget, FocusFilterMarker, UserDefaults, String, String) {
        let (defaults, name) = freshDefaults()
        let target = FakeFilterTarget()
        var setup = FocusSetup(name: "Writing")
        setup.categoryIDs = ["social"]
        target.setups = [setup]
        return (target, FocusFilterMarker(defaults: defaults), defaults, name, setup.id.uuidString)
    }

    @Test func onStartsTheSetupWithoutAskingForBrowserAccessAndRemembersIt() throws {
        let (target, marker, defaults, name, id) = rig()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(try FocusFilter.activate(setupID: id, on: target, marker: marker) == .started)
        #expect(target.inner.started.count == 1)
        #expect(target.inner.started.first?.asksBrowserAccess == false)
        #expect(marker.startedAt == target.sessionStartedAt)
        #expect(marker.startedAt != nil)
    }

    @Test func offEndsWhatTheFilterStarted() throws {
        let (target, marker, defaults, name, id) = rig()
        defer { defaults.removePersistentDomain(forName: name) }
        try FocusFilter.activate(setupID: id, on: target, marker: marker)
        #expect(FocusFilter.deactivate(on: target, marker: marker) == .ended)
        #expect(target.inner.state == .idle)
        #expect(marker.startedAt == nil)
    }

    @Test func offSurvivesARelaunch() throws {
        let (target, marker, defaults, name, id) = rig()
        defer { defaults.removePersistentDomain(forName: name) }
        try FocusFilter.activate(setupID: id, on: target, marker: marker)
        // The same session and the same defaults, a new reader.
        #expect(FocusFilter.deactivate(on: target, marker: FocusFilterMarker(defaults: defaults)) == .ended)
    }

    @Test func aSessionAlreadyOnIsNeverReplaced() throws {
        let (target, marker, defaults, name, id) = rig()
        defer { defaults.removePersistentDomain(forName: name) }
        target.startByHand(at: Date(timeIntervalSinceReferenceDate: 5))
        #expect(try FocusFilter.activate(setupID: id, on: target, marker: marker) == .keptWhatWasOn)
        #expect(target.inner.started.isEmpty)
        #expect(marker.startedAt == nil)
        // And turning the Focus off then leaves the user's own session be.
        #expect(FocusFilter.deactivate(on: target, marker: marker) == .nothingToEnd)
        #expect(target.inner.state == .running)
    }

    @Test func aBreakIsNotReplacedEither() throws {
        let (target, marker, defaults, name, id) = rig()
        defer { defaults.removePersistentDomain(forName: name) }
        target.inner.state = .onBreak
        #expect(try FocusFilter.activate(setupID: id, on: target, marker: marker) == .keptWhatWasOn)
        #expect(target.inner.started.isEmpty)
    }

    @Test func aStrictSessionIsNeverEnded() throws {
        let (target, marker, defaults, name, id) = rig()
        defer { defaults.removePersistentDomain(forName: name) }
        var strictSetup = FocusSetup(name: "Locked in")
        strictSetup.strict = true
        strictSetup.categoryIDs = ["social"]
        target.setups = [strictSetup]
        try FocusFilter.activate(setupID: strictSetup.id.uuidString, on: target, marker: marker)
        #expect(target.inner.isStrict)
        #expect(FocusFilter.deactivate(on: target, marker: marker) == .leftRunning)
        #expect(target.inner.state == .running)
        #expect(target.inner.endCalls == 0)
        #expect(marker.startedAt == nil)
    }

    @Test func aSessionTheUserStartedAfterwardsIsLeftAlone() throws {
        let (target, marker, defaults, name, id) = rig()
        defer { defaults.removePersistentDomain(forName: name) }
        try FocusFilter.activate(setupID: id, on: target, marker: marker)
        // The filter's session ends some other way; the user starts another.
        target.inner.state = .idle
        target.startByHand(at: Date(timeIntervalSinceReferenceDate: 900_000_000))
        #expect(FocusFilter.deactivate(on: target, marker: marker) == .leftRunning)
        #expect(target.inner.state == .running)
        #expect(marker.startedAt == nil)
    }

    @Test func aStaleNoteIsClearedWhenSomethingElseIsOn() throws {
        let (target, marker, defaults, name, id) = rig()
        defer { defaults.removePersistentDomain(forName: name) }
        marker.startedAt = Date(timeIntervalSinceReferenceDate: 42)
        target.startByHand(at: Date(timeIntervalSinceReferenceDate: 43))
        #expect(try FocusFilter.activate(setupID: id, on: target, marker: marker) == .keptWhatWasOn)
        #expect(marker.startedAt == nil)
    }

    @Test func aRepeatedOnKeepsTheNoteOfTheSessionItStarted() throws {
        let (target, marker, defaults, name, id) = rig()
        defer { defaults.removePersistentDomain(forName: name) }
        try FocusFilter.activate(setupID: id, on: target, marker: marker)
        let first = marker.startedAt
        #expect(try FocusFilter.activate(setupID: id, on: target, marker: marker) == .keptWhatWasOn)
        #expect(marker.startedAt == first)
        #expect(FocusFilter.deactivate(on: target, marker: marker) == .ended)
    }

    @Test func aDeletedSetupFailsInsteadOfStartingTheDefaults() {
        let (target, marker, defaults, name, _) = rig()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(throws: FocusIntentError.setupNotFound) {
            try FocusFilter.activate(setupID: UUID().uuidString, on: target, marker: marker)
        }
        #expect(target.inner.started.isEmpty)
    }

    @Test func offWithNothingRememberedDoesNothing() {
        let (target, marker, defaults, name, _) = rig()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(FocusFilter.deactivate(on: target, marker: marker) == .nothingToEnd)
        #expect(target.inner.endCalls == 0)
    }

    /// A setup whose start Shortcut turns on a Focus whose filter starts the
    /// same setup: the Focus turning on finds the session already running and
    /// does nothing, so the two cannot start each other forever.
    @Test func aSetupAndAFocusThatStartEachOtherSettleAfterOneStart() throws {
        let (target, marker, defaults, name, id) = rig()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(try FocusFilter.activate(setupID: id, on: target, marker: marker) == .started)
        // The setup's start Shortcut turns the Focus on; its filter fires again.
        for _ in 0..<3 {
            #expect(try FocusFilter.activate(setupID: id, on: target, marker: marker) == .keptWhatWasOn)
        }
        #expect(target.inner.started.count == 1)
    }
}
