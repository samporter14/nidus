//
//  WorkspaceLauncher.swift
//  Nidus
//
//  What a saved workspace opens when a session starts: apps, documents,
//  folders and web pages, and the Shortcuts it runs. Everything that touches
//  the Mac goes through `WorkspaceOpening` (NSWorkspace for apps, files and
//  pages; `FocusShortcuts.run` for Shortcuts) and every file is found again
//  through `BookmarkResolving`, so the tests count calls on fakes and never
//  open a real file, page or app.
//
//  Nidus is not sandboxed (Scripts/build-app.sh signs with no entitlements),
//  so a bookmark is a plain one: it follows a file that was moved or renamed
//  and needs no security scope. If Nidus is ever sandboxed, `SystemBookmarks`
//  is the one place to ask for scoped bookmarks.
//
//  A file that can't be found is not an error that stops the rest: it is
//  collected in a `WorkspaceReport`, and the caller says so once.
//
//  Shared by the app and its tests.
//

import AppKit

// MARK: - The Mac's side

/// Everything a workspace does to the Mac. The real one is
/// `SystemWorkspaceOpener`; tests record calls on a fake.
@MainActor
protocol WorkspaceOpening: AnyObject {
    /// Opens work apps by bundle identifier. With `activating`, the first
    /// comes to the front and the rest open behind it.
    func openApplications(_ bundleIDs: [String], activating: Bool)
    /// Opens a file or folder with its usual app, or a web page in the
    /// default browser. False when nothing could open it.
    @discardableResult func open(_ url: URL) -> Bool
    /// Runs a Shortcut by name, passed as one argument and never as text in
    /// a command line.
    func runShortcut(_ name: String) async
}

@MainActor
final class SystemWorkspaceOpener: WorkspaceOpening {
    func openApplications(_ bundleIDs: [String], activating: Bool) {
        for (index, bundleID) in bundleIDs.enumerated() {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = activating && index == 0
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }

    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    func runShortcut(_ name: String) async {
        await FocusShortcuts.run(name)
    }
}

/// Opens nothing and runs nothing. A demo or a render has no business
/// starting apps, files, pages or Shortcuts on the Mac it is drawn on.
@MainActor
final class NullWorkspaceOpener: WorkspaceOpening {
    func openApplications(_ bundleIDs: [String], activating: Bool) {}
    func open(_ url: URL) -> Bool { true }
    func runShortcut(_ name: String) async {}
}

/// Bookmarks to files and folders. The real one asks the system; tests hand
/// out their own data and say where it now points.
protocol BookmarkResolving: Sendable {
    /// A bookmark to this file or folder, or nil when one can't be made.
    func bookmark(for url: URL) -> Data?
    /// Where a bookmark points now, and whether it should be made again
    /// (the system found the file by a different route than it recorded).
    /// nil when it doesn't point anywhere.
    func resolve(_ bookmark: Data) -> (url: URL, isStale: Bool)?
}

struct SystemBookmarks: BookmarkResolving {
    func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolve(_ bookmark: Data) -> (url: URL, isStale: Bool)? {
        var stale = false
        // No UI, and a volume that isn't mounted stays unmounted: finding a
        // file must never put up a dialog or reach for a server.
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }
}

/// Which app opens a file. The real one asks Launch Services, which only
/// answers; nothing is opened. Tests say what opens what.
protocol DefaultAppFinding: Sendable {
    /// The app that opens this file or folder by default, or nil when none does.
    func appToOpen(_ url: URL) -> BlockedApp?
}

struct SystemAppFinder: DefaultAppFinding {
    func appToOpen(_ url: URL) -> BlockedApp? {
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url),
              let bundleID = Bundle(url: appURL)?.bundleIdentifier else { return nil }
        let name = FileManager.default.displayName(atPath: appURL.path)
        return BlockedApp(bundleID: bundleID, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
    }
}

/// Knows of no app: a demo or a render has nothing to ask.
struct NullAppFinder: DefaultAppFinding {
    func appToOpen(_ url: URL) -> BlockedApp? { nil }
}

// MARK: - A resource, found again

/// Why a document, folder or page could not be opened.
enum WorkspaceProblemReason: Equatable, Sendable {
    /// The bookmark and the path both lead nowhere.
    case notFound
    /// The file is where the Trash keeps it: moved there, not wanted.
    case inTrash
    /// A page whose address is not an http or https one.
    case notAWebAddress
    /// The Mac declined to open it.
    case couldNotOpen
}

/// What a resource resolves to.
enum WorkspaceLocation: Equatable, Sendable {
    /// A file or folder, at this place now. `refreshed` is the resource with
    /// a bookmark and path that match it, when they had gone out of date.
    case file(URL, refreshed: WorkspaceResource?)
    case page(URL)
    case unavailable(WorkspaceProblemReason)

    var url: URL? {
        switch self {
        case .file(let url, _), .page(let url): return url
        case .unavailable: return nil
        }
    }

    var problem: WorkspaceProblemReason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

extension WorkspaceResource {
    /// What lists and cards call it: the name it was given, else the file's
    /// name, else the address.
    var shownName: String {
        for candidate in [displayName, path.map { ($0 as NSString).lastPathComponent } ?? "", url ?? ""] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "Untitled"
    }

    /// The page's address as a URL, but only for http and https. Read the
    /// same way when a page is added and when it is opened, so a hand-edited
    /// file can't make a workspace open anything else.
    static func openableAddress(_ text: String?) -> URL? {
        guard let text, text.count <= webAddressLimit, WebPage(text) != nil else { return nil }
        return URL(string: text)
    }

    static let webAddressLimit = 2048
}

/// Finds the files a workspace holds and opens what it can.
struct WorkspaceLauncher {
    var bookmarks: any BookmarkResolving = SystemBookmarks()
    var fileExists: @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }

    /// Where a resource is now. A file is looked for by its bookmark first
    /// (which follows a move or a rename), then by the path it was chosen
    /// at. Moving to the Trash doesn't make a file missing to a bookmark, so
    /// a file in the Trash counts as gone.
    func locate(_ resource: WorkspaceResource) -> WorkspaceLocation {
        switch resource.kind {
        case .webPage:
            guard let url = WorkspaceResource.openableAddress(resource.url) else { return .unavailable(.notAWebAddress) }
            return .page(url)
        case .document, .folder:
            return locateFile(resource)
        }
    }

    private func locateFile(_ resource: WorkspaceResource) -> WorkspaceLocation {
        var sawTrash = false
        var found: URL?
        var stale = false
        if let data = resource.bookmark, let resolved = bookmarks.resolve(data) {
            if Self.isInTrash(resolved.url) {
                sawTrash = true
            } else if fileExists(resolved.url) {
                found = resolved.url
                stale = resolved.isStale
            }
        }
        if found == nil, let path = resource.path, !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if Self.isInTrash(url) {
                sawTrash = true
            } else if fileExists(url) {
                found = url
                // The bookmark pointed elsewhere or nowhere; make it again.
                stale = true
            }
        }
        guard let url = found else { return .unavailable(sawTrash ? .inTrash : .notFound) }
        // Made again when the system says so, or when the file is no longer
        // where the setup remembers it, so the next start is exact.
        let moved = resource.path.map { URL(fileURLWithPath: $0).standardizedFileURL.path != url.standardizedFileURL.path } ?? true
        guard stale || moved else { return .file(url, refreshed: nil) }
        var refreshed = resource
        refreshed.bookmark = bookmarks.bookmark(for: url) ?? resource.bookmark
        refreshed.path = url.path
        refreshed.displayName = url.lastPathComponent
        return .file(url, refreshed: refreshed == resource ? nil : refreshed)
    }

    static func isInTrash(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    /// Opens every resource it can, in order, and reports the rest.
    @MainActor
    func open(_ resources: [WorkspaceResource], using opener: any WorkspaceOpening) -> WorkspaceReport {
        var report = WorkspaceReport(total: resources.count)
        for resource in resources {
            let location = locate(resource)
            switch location {
            case .unavailable(let reason):
                report.problems.append(.init(resourceID: resource.id, name: resource.shownName, kind: resource.kind, reason: reason))
            case .file(let url, let refreshed):
                if let refreshed { report.refreshed.append(refreshed) }
                if opener.open(url) {
                    report.opened += 1
                } else {
                    report.problems.append(.init(resourceID: resource.id, name: resource.shownName, kind: resource.kind, reason: .couldNotOpen))
                }
            case .page(let url):
                if opener.open(url) {
                    report.opened += 1
                } else {
                    report.problems.append(.init(resourceID: resource.id, name: resource.shownName, kind: resource.kind, reason: .couldNotOpen))
                }
            }
        }
        return report
    }
}

// MARK: - What happened

/// How opening a workspace came out, to be said once.
struct WorkspaceReport: Equatable, Sendable {
    struct Problem: Equatable, Sendable {
        var resourceID: UUID
        var name: String
        var kind: WorkspaceResource.Kind
        var reason: WorkspaceProblemReason
    }

    var total = 0
    var opened = 0
    var problems: [Problem] = []
    /// Resources whose bookmark was made again, to be saved with the setup.
    var refreshed: [WorkspaceResource] = []

    var isClean: Bool { problems.isEmpty }

    /// "Opened 2 of 3."
    var headline: String { "Opened \(opened) of \(total)." }

    /// What is wrong, in plain words, and what to do about it:
    /// "Aims.docx can't be found. Choose it again in the setup."
    var detail: String {
        var sentences: [String] = []
        var choosable = 0
        for reason in [WorkspaceProblemReason.notFound, .inTrash, .notAWebAddress, .couldNotOpen] {
            let names = problems.filter { $0.reason == reason }.map(\.name)
            guard !names.isEmpty else { continue }
            if reason == .notFound || reason == .inTrash { choosable += names.count }
            let subject = Self.list(names)
            let plural = names.count > 1
            switch reason {
            case .notFound: sentences.append("\(subject) can\u{2019}t be found.")
            case .inTrash: sentences.append("\(subject) \(plural ? "are" : "is") in the Trash.")
            case .notAWebAddress: sentences.append("\(subject) \(plural ? "aren\u{2019}t" : "isn\u{2019}t") a web address.")
            case .couldNotOpen: sentences.append("\(subject) didn\u{2019}t open.")
            }
        }
        if choosable > 0 {
            sentences.append(choosable == 1 ? "Choose it again in the setup." : "Choose them again in the setup.")
        }
        return sentences.joined(separator: " ")
    }

    /// "A", "A and B", "A, B and 1 more": a card has one line for them.
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }
}

// MARK: - Making a resource

extension WorkspaceResource {
    enum AddressProblem: Error, Equatable, Sendable {
        /// Nothing typed: nothing to say about it.
        case empty
        case notAWebAddress

        var message: String? {
            switch self {
            case .empty: return nil
            case .notAWebAddress: return WebsiteExceptionProblem.notAWebAddress.message
            }
        }
    }

    /// A web page from what was typed or pasted. http and https only: a
    /// scheme-less address gets https, and anything else (a file, a script,
    /// a mail link, an address with a login in it) is refused. The address
    /// is kept as typed, apart from the scheme.
    static func webPage(from input: String) -> Result<WorkspaceResource, AddressProblem> {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        if let scheme = text.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*://"#, options: .regularExpression) {
            guard ["http://", "https://"].contains(text[scheme].lowercased()) else { return .failure(.notAWebAddress) }
        } else if text.hasPrefix("//") {
            text = "https:" + text
        } else {
            text = "https://" + text
        }
        // The exceptions' reading decides what is an address: its host, its
        // port, and that it carries no login. Then the page reads it too.
        guard case .success = WebsiteException.draft(from: text, kind: .exact),
              openableAddress(text) != nil else { return .failure(.notAWebAddress) }
        // As it was written, without the scheme or a leading "www.".
        var name = text.replacingOccurrences(of: #"^https?://(www\.)?"#, with: "", options: [.regularExpression, .caseInsensitive])
        if name.hasSuffix("/") { name.removeLast() }
        if name.count > 60 { name = String(name.prefix(59)) + "\u{2026}" }
        return .success(WorkspaceResource(kind: .webPage, displayName: name, url: text))
    }

    /// A document or folder chosen in the Open panel. A package (a Pages
    /// document, an app) is one document, not a folder to look in.
    static func file(at url: URL, bookmarks: any BookmarkResolving = SystemBookmarks()) -> WorkspaceResource {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let isFolder = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
        return WorkspaceResource(kind: isFolder ? .folder : .document, displayName: url.lastPathComponent,
                                 bookmark: bookmarks.bookmark(for: url), path: url.path)
    }

    /// The same document or folder chosen again: it keeps its place in the
    /// setup and takes the new file's bookmark, path and name.
    func choosing(_ url: URL, bookmarks: any BookmarkResolving = SystemBookmarks()) -> WorkspaceResource {
        var chosen = Self.file(at: url, bookmarks: bookmarks)
        chosen.id = id
        return chosen
    }
}
