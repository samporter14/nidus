//
//  ActivityProjectTitle.swift
//  Nidus
//
//  Coding apps' window titles name a file, a folder and the app, or a shell
//  and a terminal size. Only the project is kept: the Xcode project, the
//  folder open in VS Code or Cursor, the working directory a terminal shows.
//  File names, shells, hosts and sizes are dropped before anything is
//  stored, so coding time splits by project and by nothing finer. Read only
//  with "Keep page and window names" on, like every other title.
//
//  Pure, so every parser is tested against real-looking titles.
//

import Foundation

enum ActivityProjectTitle {
    static let xcodeID = "com.apple.dt.Xcode"
    static let vsCodeIDs: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium"]
    static let cursorID = "com.todesktop.230313mzl4w4u92"
    static let terminalID = "com.apple.Terminal"
    static let iTermID = "com.googlecode.iterm2"

    /// Apps whose window title is read for a project name.
    static let apps: Set<String> = vsCodeIDs.union([xcodeID, cursorID, terminalID, iTermID])

    static func isProjectApp(_ bundleID: String?) -> Bool { bundleID.map(apps.contains) ?? false }

    /// The project a coding app's window title names, or nil when it names
    /// none (a welcome window, a bare shell, the home folder).
    static func project(from raw: String?, bundleID: String, home: String = NSHomeDirectory()) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let name: String?
        switch bundleID {
        case xcodeID: name = xcode(raw)
        case cursorID: name = editor(raw, appNames: ["Cursor"])
        case _ where vsCodeIDs.contains(bundleID):
            name = editor(raw, appNames: ["Visual Studio Code", "Visual Studio Code - Insiders", "VSCodium", "Code"])
        case terminalID, iTermID: name = terminal(raw, home: home)
        default: name = nil
        }
        return name.flatMap(tidy)
    }

    // MARK: Xcode

    /// "Nidus — FocusActivityPage.swift", "Nidus — Edited", "Nidus".
    static func xcode(_ title: String) -> String? {
        let parts = pieces(title)
        guard var first = parts.first else { return nil }
        for suffix in [".xcodeproj", ".xcworkspace", ".swiftpm"] where first.lowercased().hasSuffix(suffix) {
            first = String(first.dropLast(suffix.count))
        }
        let windows: Set<String> = ["welcome to xcode", "xcode", "organizer", "settings", "devices and simulators",
                                    "simulator", "instruments", "documentation", "developer documentation",
                                    "accessibility inspector", "package.swift"]
        return windows.contains(first.lowercased()) ? nil : first
    }

    // MARK: VS Code and Cursor

    /// "● FocusActivityPage.swift — nidus — Visual Studio Code",
    /// "nidus — Cursor", "README.md — site (Workspace) — Visual Studio Code",
    /// "[SSH: devbox] main.py — api — Visual Studio Code". The folder is the
    /// last piece before the app's name; with one piece left it is the
    /// folder unless it looks like a file or an editor tab.
    static func editor(_ title: String, appNames: Set<String>) -> String? {
        var parts = pieces(title)
        if let last = parts.last, appNames.contains(last) { parts.removeLast() }
        parts = parts.map { strip(brackets: $0) }.filter { !$0.isEmpty }
        guard let folder = parts.last else { return nil }
        var name = folder
        for marker in [" (Workspace)", " (Extension Development Host)"] where name.hasSuffix(marker) {
            name = String(name.dropLast(marker.count))
        }
        if parts.count == 1, looksLikeFile(name) || editorTabs.contains(name.lowercased()) { return nil }
        if editorTabs.contains(name.lowercased()) || name.hasPrefix("Extension: ") { return nil }
        return name
    }

    private static let editorTabs: Set<String> = ["welcome", "settings", "keyboard shortcuts", "extensions",
                                                  "release notes", "get started", "untitled", "walkthrough",
                                                  "search", "source control", "output", "problems",
                                                  "visual studio code", "cursor", "cursor settings"]

    // MARK: Terminal and iTerm

    /// Terminal: "nidus — -zsh — 80×24", "nidus — swift-build ◂ zsh — 120×40",
    /// "sam@mac: ~/Documents/nidus". iTerm: "nidus (-zsh)",
    /// "~/Documents/nidus (zsh)", "-zsh". The working directory's folder,
    /// unless it is the home folder or the title shows only a shell.
    static func terminal(_ title: String, home: String) -> String? {
        let parts = pieces(title)
        guard var candidate = parts.first else { return nil }
        // iTerm: "dir (job)".
        if let open = candidate.range(of: " ("), candidate.hasSuffix(")") {
            candidate = String(candidate[..<open.lowerBound])
        }
        // Shell prompts: "user@host: ~/path" or "user@host:~/path".
        if let colon = candidate.firstIndex(of: ":"), candidate[..<colon].contains("@") {
            candidate = String(candidate[candidate.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        if candidate.contains("/") {
            let path = candidate.hasPrefix("~") ? home + candidate.dropFirst() : candidate
            if (path as NSString).standardizingPath == (home as NSString).standardizingPath { return nil }
            candidate = (path as NSString).lastPathComponent
        }
        let homeName = (home as NSString).lastPathComponent
        let shells: Set<String> = ["zsh", "bash", "fish", "sh", "tcsh", "login", "nu", "ssh", "tmux", "vim", "nvim", "top"]
        let bare = candidate.hasPrefix("-") ? String(candidate.dropFirst()) : candidate
        if candidate == "~" || candidate == "/" || candidate == homeName || shells.contains(bare.lowercased()) { return nil }
        if candidate.range(of: #"^\d+\s*[×x]\s*\d+$"#, options: .regularExpression) != nil { return nil }
        // A Terminal title with only one piece is a custom title or a
        // process, not a folder, unless iTerm drew it as "dir (job)".
        if parts.count == 1, !title.hasSuffix(")"), !title.contains("/") { return nil }
        return candidate
    }

    // MARK: Pieces

    /// A title's pieces, split on the em dash (macOS) or a spaced hyphen.
    static func pieces(_ title: String) -> [String] {
        let dashed = title.replacingOccurrences(of: " – ", with: " — ")
        let separator = dashed.contains(" — ") ? " — " : " - "
        return dashed.components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("● ") ? String($0.dropFirst(2)) : $0 }
            .filter { !$0.isEmpty }
    }

    /// Drops "[SSH: devbox]", "[Extension Development Host]" and the like.
    private static func strip(brackets text: String) -> String {
        text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// "main.py", "README.md", "Untitled-1": a file, not a folder.
    private static func looksLikeFile(_ text: String) -> Bool {
        text.range(of: #"^[^\s/]+\.[A-Za-z0-9]{1,8}$"#, options: .regularExpression) != nil
            || text.range(of: #"^Untitled-\d+$"#, options: .regularExpression) != nil
    }

    /// The same cleaning every title gets, and a length a name fits in.
    private static func tidy(_ name: String) -> String? {
        guard let clean = ActivityProbe.cleanTitle(name), clean.count <= 80 else { return nil }
        return clean
    }
}
