//
//  ResumeResources.swift
//  Nidus
//
//  The link a resume note can carry: a document or folder (held by bookmark,
//  so one that was moved is still found) or an http(s) web page. Building and
//  resolving them is here, apart from any panel or workspace, so it is tested
//  with temporary files. Nothing here opens anything.
//

import Foundation

enum ResumeResources {
    // MARK: Making one

    /// A file or folder the person chose, kept as a bookmark with its path
    /// and name. nil if it can't be read.
    static func resource(forFile url: URL) -> WorkspaceResource? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        // A package (.pages, .app) is one document in Finder, not a folder.
        let isFolder = values?.isDirectory == true && values?.isPackage != true
        guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return nil }
        return WorkspaceResource(kind: isFolder ? .folder : .document, displayName: url.lastPathComponent,
                                 bookmark: bookmark, path: url.path)
    }

    static let addressLimit = 2048

    /// A web page from what was typed or pasted: http or https only, with a
    /// host, no sign-in details in it. An address typed without a scheme
    /// ("example.org/aims") is taken as https. Anything else (`file:`,
    /// `javascript:`, an app's own scheme, text with spaces) is nil.
    static func webPage(from text: String) -> WorkspaceResource? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, typed.count <= addressLimit,
              typed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let full = typed.contains("://") ? typed : "https://" + typed
        guard var parts = URLComponents(string: full),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let typedHost = parts.host, !typedHost.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        // Scheme and host are not case sensitive; the path and query are.
        let host = typedHost.lowercased()
        parts.scheme = scheme
        parts.host = host
        guard let url = parts.url else { return nil }
        var label = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if parts.path.count > 1 { label += parts.path }
        return WorkspaceResource(kind: .webPage, displayName: String(label.prefix(60)), url: url.absoluteString)
    }

    // MARK: Finding it again

    enum Resolution: Equatable, Sendable {
        /// The file or folder, and a fresh copy of the resource when its
        /// bookmark had gone stale (the file moved) so it can be saved.
        case file(URL, refreshed: WorkspaceResource?)
        case page(URL)
        /// Not found; the name to say so with.
        case missing(String)
    }

    static func resolve(_ resource: WorkspaceResource) -> Resolution {
        switch resource.kind {
        case .webPage:
            // Checked again here: a hand-edited file is not trusted to be
            // an address worth opening.
            guard let text = resource.url, let page = webPage(from: text), let url = page.url.flatMap(URL.init(string:)),
                  text.lowercased().hasPrefix("http") else { return .missing(resource.displayName) }
            return .page(url)
        case .document, .folder:
            if let data = resource.bookmark {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                      relativeTo: nil, bookmarkDataIsStale: &stale),
                   FileManager.default.fileExists(atPath: url.path) {
                    return .file(url, refreshed: stale ? Self.resource(forFile: url).map { fresh in
                        var kept = fresh
                        kept.id = resource.id
                        return kept
                    } : nil)
                }
            }
            if let path = resource.path, FileManager.default.fileExists(atPath: path) {
                let url = URL(fileURLWithPath: path)
                return .file(url, refreshed: self.resource(forFile: url).map { fresh in
                    var kept = fresh
                    kept.id = resource.id
                    return kept
                })
            }
            return .missing(resource.displayName)
        }
    }

    /// The symbol a row shows for a link.
    static func symbol(for kind: WorkspaceResource.Kind) -> String {
        switch kind {
        case .document: "doc"
        case .folder: "folder"
        case .webPage: "globe"
        }
    }
}
