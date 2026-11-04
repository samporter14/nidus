import AppKit
import Testing
@testable import Nidus

@MainActor
struct PopoverLifetimeTests {
    @Test func dismissalReleasesThePresentationAndPreservesComposerValues() {
        let model = NidusModel()
        model.goalDraft = "Finish the opening paragraph"
        let length = CustomLengthDraft(text: "1h30")
        model.customLengthDraft = length
        let presentation = FocusPopoverPresentation()
        weak var releasedPopover: NSPopover?
        weak var releasedHosting: NSViewController?

        // Exercise the delegate callback without showing a window or touching
        // the user's real menu bar. Drain AppKit's temporary retained values
        // before checking actual object lifetime, not just optional properties.
        autoreleasepool {
            let popover = presentation.prepare(model: model)
            releasedPopover = popover
            releasedHosting = popover.contentViewController
            #expect(releasedHosting != nil)
            presentation.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: popover))
            #expect(presentation.popover == nil)
            #expect(popover.contentViewController == nil)
            #expect(popover.delegate == nil)
        }

        #expect(releasedPopover == nil)
        #expect(releasedHosting == nil, "Closing must release the hosting controller, not just hide its window")
        #expect(model.goalDraft == "Finish the opening paragraph")
        #expect(model.customLengthDraft == length)
    }

    @Test func reopeningCreatesFreshContentAndIgnoresThePreviousCloseCallback() throws {
        let model = NidusModel()
        let presentation = FocusPopoverPresentation()
        defer { presentation.close() }
        let first = presentation.prepare(model: model)
        let firstHosting = try #require(first.contentViewController)
        presentation.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: first))

        model.goalDraft = "Keep writing"
        let second = presentation.prepare(model: model)
        let secondHosting = try #require(second.contentViewController)
        #expect(second !== first)
        #expect(secondHosting !== firstHosting)
        #expect(presentation.prepare(model: model) === second,
                "An open presentation must be reused until it closes")

        // A delayed callback from the old presentation cannot discard a new
        // one that has already been prepared in response to another click.
        presentation.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: first))
        #expect(presentation.popover === second)
        #expect(second.contentViewController === secondHosting)
        #expect(second.delegate === presentation)
        #expect(model.goalDraft == "Keep writing")
    }

    @Test func shutdownReleasesAPreparedPopoverEvenIfItWasNeverShown() {
        let model = NidusModel()
        model.goalDraft = "Still here"
        let presentation = FocusPopoverPresentation()
        weak var releasedHosting: NSViewController?
        autoreleasepool {
            let popover = presentation.prepare(model: model)
            #expect(!popover.isShown)
            releasedHosting = popover.contentViewController
            #expect(releasedHosting != nil)
            presentation.close()
            presentation.close()
            #expect(presentation.popover == nil)
            #expect(popover.contentViewController == nil)
            #expect(popover.delegate == nil)
        }
        #expect(releasedHosting == nil)
        #expect(model.goalDraft == "Still here")
    }
}
