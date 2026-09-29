//
//  FocusShortcuts.swift
//  Nidus
//
//  Apple Focus, through Shortcuts. macOS lets no other app switch a Focus
//  mode, but a shortcut's "Set Focus" action can, so a session can run one
//  shortcut when it starts and another when it ends. This lists the user's
//  shortcuts, runs one by name, and can make the on and off pair for any of
//  Apple's built-in Focus modes.
//
//  Everything goes through /usr/bin/shortcuts in a child process with a time
//  limit, off the main thread, so a slow or broken shortcut never holds
//  Droppy up. No DroppyKit import.
//

import AppKit

enum FocusShortcuts {
    static let tool = "/usr/bin/shortcuts"

    /// A Focus mode the Set Focus action can switch, by the identifier macOS
    /// gives it. Only Apple's built-in modes are listed: a mode the user made
    /// has an identifier that only the Focus database knows, and that file is
    /// protected, so those shortcuts are made by hand in Shortcuts.
    struct AppleFocus: Hashable, Sendable, Identifiable {
        let id: String
        let name: String
        /// The names the made shortcuts get: the file name is the shortcut's.
        var onShortcut: String { "Nidus · \(name) on" }
        var offShortcut: String { "Nidus · \(name) off" }
    }

    /// The identifiers are macOS's own (they are in its system libraries),
    /// most useful for a work session first. Each works once the user has set
    /// that Focus up in System Settings.
    static let appleFocuses: [AppleFocus] = [
        AppleFocus(id: "com.apple.donotdisturb.mode.default", name: "Do Not Disturb"),
        AppleFocus(id: "com.apple.focus.work", name: "Work"),
        AppleFocus(id: "com.apple.focus.reduce-interruptions", name: "Reduce Interruptions"),
        AppleFocus(id: "com.apple.focus.reading", name: "Reading"),
        AppleFocus(id: "com.apple.focus.personal-time", name: "Personal"),
        AppleFocus(id: "com.apple.focus.mindfulness", name: "Mindfulness"),
        AppleFocus(id: "com.apple.focus.gaming", name: "Gaming"),
        AppleFocus(id: "com.apple.donotdisturb.mode.workout", name: "Fitness"),
        AppleFocus(id: "com.apple.sleep.sleep-mode", name: "Sleep"),
    ]

    static var doNotDisturb: AppleFocus { appleFocuses[0] }
    /// The Do Not Disturb pair, named for the app.
    static var doNotDisturbOn: String { doNotDisturb.onShortcut }
    static var doNotDisturbOff: String { doNotDisturb.offShortcut }

    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: tool) }

    /// Every shortcut in the user's library, by name, in library order.
    static func list() async -> [String] {
        guard let result = await execute(["list"], timeout: 10), result.status == 0 else { return [] }
        return result.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Runs one shortcut and reports whether it finished without error.
    @discardableResult
    static func run(_ name: String) async -> Bool {
        await execute(["run", name], timeout: 30)?.status == 0
    }

    /// Writes a Focus mode's on and off shortcuts, signed, into `directory`,
    /// and returns their files. Opening a file asks the user to add it in
    /// Shortcuts; nothing is added without that click.
    static func makeShortcuts(for focus: AppleFocus, in directory: URL) async throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var signed: [URL] = []
        for (name, on) in [(focus.onShortcut, true), (focus.offShortcut, false)] {
            let unsigned = directory.appendingPathComponent("unsigned-\(focus.id)-\(on ? "on" : "off").shortcut")
            let output = directory.appendingPathComponent("\(name).shortcut")
            let data = try PropertyListSerialization.data(fromPropertyList: workflow(for: focus, enabling: on), format: .binary, options: 0)
            try data.write(to: unsigned, options: .atomic)
            try? FileManager.default.removeItem(at: output)
            let result = await execute(["sign", "--mode", "people-who-know-me", "--input", unsigned.path, "--output", output.path],
                                       timeout: 30)
            try? FileManager.default.removeItem(at: unsigned)
            guard result?.status == 0, FileManager.default.fileExists(atPath: output.path) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Shortcuts could not sign \(name)."])
            }
            signed.append(output)
        }
        return signed
    }

    /// A one-action shortcut: Set Focus, this mode, on until turned off, or
    /// off.
    static func workflow(for focus: AppleFocus, enabling on: Bool) -> [String: Any] {
        [
            "WFWorkflowClientVersion": "2605.0.5",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 4_292_093_695, "WFWorkflowIconGlyphNumber": 59_771],
            "WFWorkflowImportQuestions": [Any](),
            "WFWorkflowTypes": [Any](),
            "WFWorkflowInputContentItemClasses": [Any](),
            "WFWorkflowActions": [[
                "WFWorkflowActionIdentifier": "is.workflow.actions.dnd.set",
                "WFWorkflowActionParameters": [
                    "Enabled": on ? 1 : 0,
                    "AssertionType": "Turned Off",
                    "FocusModes": ["Identifier": focus.id, "DisplayString": focus.name],
                ] as [String: Any],
            ]],
        ]
    }

    // MARK: Running the tool

    struct Result: Sendable {
        var status: Int32
        var output: String
    }

    /// Runs the tool with a time limit; nil when it could not start or was
    /// stopped for taking too long.
    static func execute(_ arguments: [String], timeout: TimeInterval) async -> Result? {
        guard isAvailable else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                let timedOut = process.terminationReason == .uncaughtSignal
                continuation.resume(returning: timedOut ? nil : Result(status: process.terminationStatus,
                                                                         output: String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
