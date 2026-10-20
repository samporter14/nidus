import AppKit
import QuartzCore
import Testing
@testable import Nidus

@MainActor
struct GlyphRenderingTests {
    private func layers(in layer: CALayer) -> [CALayer] {
        [layer] + (layer.sublayers ?? []).flatMap { layers(in: $0) }
            + (layer.mask.map { layers(in: $0) } ?? [])
    }

    @Test func aClockTickAnimatesOnlyTheFillMask() throws {
        let view = FocusGlyphView(size: 18)
        view.show(.brain, duration: 0)
        var target = GlyphState.brain
        target.fill = 0.5
        view.show(target, duration: 1)
        let allLayers = layers(in: try #require(view.layer))
        let animated = allLayers.filter { !($0.animationKeys() ?? []).isEmpty }
        #expect(animated.count == 1)
        let changingLayer = try #require(animated.first)
        #expect(changingLayer.animationKeys() == ["path"])
        #expect(allLayers.contains { $0.mask === changingLayer },
                "the animated layer is a mask, not outline or fold geometry")
        #expect(view.state == target)
    }

    @Test func aFillUpdateLeavesAnExistingMorphAlone() throws {
        let view = FocusGlyphView(size: 18)
        view.show(.brain, duration: 2)
        let allLayers = layers(in: try #require(view.layer))
        let morphLayers = allLayers.filter { $0.superlayer != nil && $0.animation(forKey: "path") != nil }
        #expect(!morphLayers.isEmpty)
        var target = GlyphState.brain
        target.fill = 0.25
        view.show(target, duration: 0.5)
        #expect(morphLayers.allSatisfy { $0.animation(forKey: "path")?.duration == 2 })
    }

    @Test func anImmediateShowSettlesUnchangedAnimations() throws {
        let view = FocusGlyphView(size: 18)
        view.show(.brain, duration: 2)
        view.show(.brain, duration: 0)
        #expect(layers(in: try #require(view.layer)).allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        #expect(view.state == .brain)
    }
}

@MainActor
struct MenuBarAccessibilityTests {
    @Test func stateIsSpokenIndependentlyOfTheVisibleClock() {
        let status = MenuBarStatus.make(clock: "18:00", onBreak: false, openEnded: false,
                                        remaining: 18 * 60, block: nil)
        #expect(status.accessibilityValue(isActive: true, onBreak: false, isPaused: false) == "Focusing, 18:00 left")
        #expect(status.accessibilityValue(isActive: true, onBreak: false, isPaused: true) == "Paused, 18:00 left")
        #expect(status.accessibilityValue(isActive: false, onBreak: false, isPaused: false) == "Ready to focus")
    }

    @Test func aBreakAndOpenEndedSessionKeepTheirMeaning() {
        let rest = MenuBarStatus.make(clock: "04:10", onBreak: true, openEnded: false, remaining: 0, block: nil)
        #expect(rest.accessibilityValue(isActive: false, onBreak: true, isPaused: false) == "On a break, 04:10 of break left")
        let open = MenuBarStatus.make(clock: "05:00", onBreak: false, openEnded: true, remaining: 0, block: nil)
        #expect(open.accessibilityValue(isActive: true, onBreak: false, isPaused: true) == "Paused, 05:00 focused")
    }
}
