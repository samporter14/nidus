//
//  AppleEvents.swift
//  Nidus
//
//  Raw Apple Events, built by hand rather than through NSAppleScript, for
//  three reasons: every send has a timeout, so a hung browser costs at most
//  that long; the target is a process ID, so an event can never launch an app
//  that is not running; and the calls are safe off the main thread.
//
//  No DroppyKit import: this file also compiles into the spike and the tests.
//

import AppKit
import CoreServices

/// A four-character code from its string form, `"pURL"` -> 0x7055524C.
func fourCC(_ code: String) -> FourCharCode {
    code.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
}

enum AppleEventError: Error, Equatable {
    /// The app is not running. Nothing was sent.
    case notRunning
    /// Automation consent for this target was refused (-1743).
    case notPermitted
    /// Consent has never been asked for (-1744). Ask from a user action.
    case needsConsent
    /// No reply within the timeout (-1712).
    case timedOut
    /// Any other OSStatus, from the send or from the app's reply.
    case failed(Int)

    init(status: Int) {
        switch status {
        case -600: self = .notRunning
        case -1743: self = .notPermitted
        case -1744: self = .needsConsent
        case -1712: self = .timedOut
        default: self = .failed(status)
        }
    }
}

/// Object specifiers, the `tab 2 of window id 5` of an Apple Event.
enum ObjectSpecifier {
    /// The app itself, the container of top-level specifiers.
    static var application: NSAppleEventDescriptor { .null() }

    static func every(_ cls: String, of container: NSAppleEventDescriptor = application) -> NSAppleEventDescriptor {
        var all = fourCC("all ")
        let seld = NSAppleEventDescriptor(descriptorType: fourCC("abso"), bytes: &all, length: 4)!
        return make(want: fourCC(cls), form: "indx", seld: seld, from: container)
    }

    static func index(_ cls: String, _ index: Int, of container: NSAppleEventDescriptor = application) -> NSAppleEventDescriptor {
        make(want: fourCC(cls), form: "indx", seld: NSAppleEventDescriptor(int32: Int32(index)), from: container)
    }

    static func id(_ cls: String, _ id: Int, of container: NSAppleEventDescriptor = application) -> NSAppleEventDescriptor {
        make(want: fourCC(cls), form: "ID  ", seld: NSAppleEventDescriptor(int32: Int32(id)), from: container)
    }

    static func property(_ code: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        make(want: fourCC("prop"), form: "prop", seld: NSAppleEventDescriptor(typeCode: fourCC(code)), from: container)
    }

    private static func make(want: FourCharCode, form: String, seld: NSAppleEventDescriptor, from: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: fourCC("want"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: fourCC(form)), forKeyword: fourCC("form"))
        record.setDescriptor(seld, forKeyword: fourCC("seld"))
        record.setDescriptor(from, forKeyword: fourCC("from"))
        return record.coerce(toDescriptorType: fourCC("obj "))!
    }
}

/// Sends `get` and `set` to one running app, addressed by process ID.
struct AppleEventTarget {
    let processIdentifier: pid_t

    /// The first running instance of `bundleID`, or nil. Never launches it.
    init?(runningBundleID bundleID: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { !$0.isTerminated }) else { return nil }
        processIdentifier = app.processIdentifier
    }

    init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
    }

    /// Whether this process may send events to the target. With `ask`, shows
    /// the Automation prompt if the user has never answered; it blocks until
    /// they do, so only ask off the main thread and from a user action.
    func automationPermission(ask: Bool) -> AppleEventError? {
        let target = NSAppleEventDescriptor(processIdentifier: processIdentifier)
        let status = AEDeterminePermissionToAutomateTarget(
            target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        return status == noErr ? nil : AppleEventError(status: Int(status))
    }

    func get(_ specifier: NSAppleEventDescriptor, timeout: TimeInterval = 2) throws(AppleEventError) -> NSAppleEventDescriptor {
        try send("core", "getd", specifier, data: nil, timeout: timeout)
    }

    func set(_ specifier: NSAppleEventDescriptor, to value: NSAppleEventDescriptor, timeout: TimeInterval = 2) throws(AppleEventError) {
        _ = try send("core", "setd", specifier, data: value, timeout: timeout)
    }

    private func send(_ eventClass: String, _ eventID: String, _ specifier: NSAppleEventDescriptor,
                      data: NSAppleEventDescriptor?, timeout: TimeInterval) throws(AppleEventError) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: fourCC(eventClass), eventID: fourCC(eventID),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: processIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(specifier, forKeyword: fourCC("----"))
        if let data { event.setParam(data, forKeyword: fourCC("data")) }

        // kAEDoNotPromptForUserConsent: a poll must never raise the Automation
        // prompt. Consent is asked for once, from automationPermission(ask:).
        let options: NSAppleEventDescriptor.SendOptions = [.waitForReply, .neverInteract,
                                                           .init(rawValue: 0x0002_0000)]
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: options, timeout: timeout)
        } catch {
            throw AppleEventError(status: (error as NSError).code)
        }
        if let number = reply.paramDescriptor(forKeyword: fourCC("errn")), number.int32Value != 0 {
            throw AppleEventError(status: Int(number.int32Value))
        }
        return reply.paramDescriptor(forKeyword: fourCC("----")) ?? .null()
    }
}

extension NSAppleEventDescriptor {
    /// The items of a list descriptor (AppleScript lists are 1-based).
    var listItems: [NSAppleEventDescriptor] {
        guard descriptorType == fourCC("list") else { return [] }
        return numberOfItems > 0 ? (1...numberOfItems).compactMap { atIndex($0) } : []
    }
}
