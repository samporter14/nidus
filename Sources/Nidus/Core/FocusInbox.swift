//
//  FocusInbox.swift
//  Nidus
//
//  The distraction inbox: a place to put a thought or a link down during a
//  session so it stops pulling at you, to be dealt with afterwards. Two ways
//  in: the capture panel (a shortcut, or "Save a thought" in the popover) and
//  the block page's "Save for later". Nothing is fetched or opened for you:
//  an item is the words and the address you gave it, and a link opens only
//  when you press Open.
//
//  Saving never touches a session. This file knows nothing of the engine, the
//  controller or the blockers, so a strict session can't be loosened from
//  here.
//
//  The file is inbox.json in Nidus's folder, written atomically and read item
//  by item, so one item that doesn't decode costs only itself. A second file,
//  block-page-token, holds the random token the block page carries; see
//  InboxSaveToken.
//
//  Shared by the app and its tests.
//

import Foundation

// MARK: - Items

struct InboxItem: Codable, Identifiable, Equatable, Sendable {
    /// Where it came from.
    enum Source: String, Codable, Sendable {
        /// Typed into the capture panel.
        case capture
        /// "Save for later" on the block page.
        case blockedPage
    }

    var id: UUID
    /// What was said, trimmed and at most `FocusInbox.textLimit` characters.
    /// For a link saved with no words, the site's name.
    var text: String
    /// An http or https address, as `InboxURL.clean` writes it, or nil.
    var url: String?
    var source: Source
    var createdAt: Date
    var completedAt: Date?

    var isCompleted: Bool { completedAt != nil }

    init(id: UUID = UUID(), text: String, url: String? = nil, source: Source = .capture,
         createdAt: Date, completedAt: Date? = nil) {
        self.id = id
        self.text = text
        self.url = url
        self.source = source
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    /// The id, the date and some words (or an address) must be there. What
    /// else fails to decode falls back, and what is read is cleaned again:
    /// a file edited by hand or written by a later version can't put an
    /// address Nidus would not have saved, or a page of text, into the list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        let words = InboxText.clean(c.decodeTolerant(String.self, forKey: .text) ?? "")
        url = c.decodeTolerant(String.self, forKey: .url).flatMap { InboxURL.clean($0) }
        if words.isEmpty {
            guard let url else {
                throw DecodingError.dataCorruptedError(forKey: .text, in: c, debugDescription: "no text and no address")
            }
            text = InboxURL.displayText(for: url)
        } else {
            text = words
        }
        source = c.decodeTolerant(Source.self, forKey: .source) ?? .capture
        completedAt = c.decodeTolerant(Date.self, forKey: .completedAt)
    }

    enum CodingKeys: String, CodingKey { case id, text, url, source, createdAt, completedAt }
}

// MARK: - Words

enum InboxText {
    /// One line, trimmed, and short: a control character (a newline would
    /// break a row of the list) becomes a space, as a goal's does.
    static func clean(_ text: String) -> String {
        let breaks: Set<Unicode.GeneralCategory> = [.control, .lineSeparator, .paragraphSeparator]
        let flat = String(text.unicodeScalars.map { breaks.contains($0.properties.generalCategory) ? " " : Character($0) })
        let trimmed = flat.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(FocusInbox.textLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Addresses

/// Which addresses the inbox keeps, and when two are the same page. Only
/// http and https: a `javascript:`, `data:` or `file:` address is dropped (the
/// words stay), because the item's Open button hands the address to the
/// system and nothing else should be reachable that way.
enum InboxURL {
    /// Longer than any address a person means to keep (search and tracking
    /// addresses run to a few thousand characters); also keeps the file small.
    static let limit = 4096

    /// The address in canonical form, or nil when it is not an http(s) one.
    ///
    /// `assumingHTTPS` is for what a person typed (`example.com/page`): a
    /// missing scheme gets https. An address carried by a link always has its
    /// scheme, so it is read strictly. Spaces and non-ASCII characters are
    /// percent-encoded (and a Unicode host written in punycode) the way a
    /// browser would send them. An address with a name and password in it, a
    /// port out of range, or no host is refused.
    static func clean(_ text: String, assumingHTTPS: Bool = false) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= limit,
              !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }

        // `localhost:3000/x` looks like a scheme `localhost:` and is a host and port.
        let isHostAndPort = text.range(of: #"^[^/?#:@\s]+:[0-9]+([/?#]|$)"#, options: .regularExpression) != nil
        if !isHostAndPort, text.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) != nil {
            // Some scheme was written: only http:// and https:// pass.
            guard text.range(of: #"^[Hh][Tt][Tt][Pp][Ss]?://"#, options: .regularExpression) != nil else { return nil }
        } else {
            guard assumingHTTPS else { return nil }
            if text.hasPrefix("//") { text.removeFirst(2) }
            let authority = text.prefix { !"/?#".contains($0) }
            guard authority.contains(".") || authority.hasPrefix("localhost") || authority.hasPrefix("[") else { return nil }
            text = "https://" + text
        }

        guard var parts = URLComponents(string: text, encodingInvalidCharacters: true),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              parts.user == nil, parts.password == nil,
              let host = parts.host?.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased(),
              !host.isEmpty, host.count <= 253, !host.contains(where: \.isWhitespace) else { return nil }
        if let port = parts.port, !(1...65535).contains(port) { return nil }
        parts.scheme = scheme
        parts.host = host
        guard let canonical = parts.string, canonical.count <= limit else { return nil }
        return canonical
    }

    /// What two addresses must share to be the same page: the host without
    /// `www.`, the port when it is not the scheme's own, the path without a
    /// trailing slash and with its escapes undone, and the query. Not the
    /// scheme (http and https are the page to anyone saving it) or the
    /// fragment. nil for what `clean` refuses.
    static func key(for address: String) -> String? {
        guard let canonical = clean(address), let parts = URLComponents(string: canonical),
              var host = parts.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var key = host
        if let port = parts.port, port != 80, port != 443 { key += ":\(port)" }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        key += path
        if let query = parts.percentEncodedQuery, !query.isEmpty { key += "?" + query }
        return key
    }

    /// The site's name, for an item saved with no words: `youtube.com`.
    static func displayText(for address: String) -> String {
        guard let host = URLComponents(string: address)?.host?.lowercased() else { return address }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: - The block page's token

/// A random token written into the block page when it is installed, and kept
/// in Nidus's folder beside the other files, never in preferences. The page's
/// "Save for later" link carries it, and Nidus ignores a save link without it.
///
/// Any web page can open a `nidus://` link, and a save would put its address
/// in your inbox. A web page can't read a file on this Mac, so only the block
/// page, which is one, can carry the token. It guards the inbox, not a
/// session: nothing a save does could loosen one.
enum InboxSaveToken {
    static let fileName = "block-page-token"

    /// 32 random bytes as 64 hex digits.
    static func isWellFormed(_ token: String) -> Bool {
        token.utf8.count == 64 && token.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    /// The token, made on first use. A file that does not hold one is
    /// replaced. The file is private to the person (0600) from the moment it
    /// exists, and put in place whole. nil when it can't be written, in which
    /// case the block page leaves out its Save for later button.
    static func loadOrCreate(in directory: URL) -> String? {
        if let existing = read(in: directory) { return existing }
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let fileManager = FileManager.default
        let final = directory.appendingPathComponent(fileName)
        let temporary = directory.appendingPathComponent(fileName + ".new")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: temporary)
        guard fileManager.createFile(atPath: temporary.path, contents: Data(token.utf8),
                                     attributes: [.posixPermissions: 0o600]) else { return nil }
        try? fileManager.removeItem(at: final)
        do { try fileManager.moveItem(at: temporary, to: final) } catch { return nil }
        return token
    }

    static func read(in directory: URL) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              isWellFormed(text) else { return nil }
        return text
    }

    /// Whether `candidate` is this folder's token. Compares every byte
    /// whatever the first difference, as a habit for a secret.
    static func matches(_ candidate: String, in directory: URL) -> Bool {
        guard let expected = read(in: directory) else { return false }
        let a = Array(expected.utf8), b = Array(candidate.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}

// MARK: - The store

@MainActor
final class FocusInbox {
    struct File: Codable {
        var version = 1
        var items: [InboxItem]

        init(version: Int = 1, items: [InboxItem]) {
            self.version = version
            self.items = items
        }

        /// Item by item: one that doesn't decode is dropped, not the file.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = c.decodeTolerant(Int.self, forKey: .version) ?? 1
            items = try c.decode(LossyArray<InboxItem>.self, forKey: .items).elements
        }

        enum CodingKeys: String, CodingKey { case version, items }
    }

    nonisolated static let fileName = "inbox.json"
    /// The words of one item.
    nonisolated static let textLimit = 280
    /// The same address saved again within this long adds nothing: a reload,
    /// a sweep that put the block page up twice, a link fired twice.
    nonisolated static let duplicateWindow: TimeInterval = 10 * 60
    /// A completed item is deleted this long after it was completed. An open
    /// one stays until it is deleted.
    nonisolated static let completedRetention: TimeInterval = 30 * 24 * 60 * 60

    let directory: URL
    let url: URL
    private let now: () -> Date
    private(set) var items: [InboxItem] = []
    /// Called after every change, for the views.
    var onChange: (() -> Void)?

    init(directory: URL, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.url = directory.appendingPathComponent(Self.fileName)
        self.now = now
        if let data = try? Data(contentsOf: url) {
            if let file = try? JSONDecoder().decode(File.self, from: data) {
                items = file.items
            } else {
                // Not an inbox file Nidus can read. Starting empty would write
                // over it at the next save, so it is put aside first, intact.
                FocusHistory.setAside(url, now: now())
            }
        }
        if pruneExpired() { save() }
    }

    // MARK: Reading

    /// Newest first.
    var openItems: [InboxItem] {
        newestFirst(items.filter { !$0.isCompleted })
    }

    /// By date, and where two share one, the one saved later first.
    private func newestFirst(_ list: [InboxItem]) -> [InboxItem] {
        list.enumerated().sorted { ($0.element.createdAt, $0.offset) > ($1.element.createdAt, $1.offset) }.map(\.element)
    }

    /// Most recently completed first.
    var completedItems: [InboxItem] {
        items.filter(\.isCompleted).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    var openCount: Int { items.reduce(0) { $0 + ($1.isCompleted ? 0 : 1) } }

    /// How many were put in at or after `date`, done or not: what the wrap-up
    /// card calls saved during the session.
    func count(since date: Date) -> Int {
        items.reduce(0) { $0 + ($1.createdAt >= date ? 1 : 0) }
    }

    func item(_ id: InboxItem.ID) -> InboxItem? { items.first { $0.id == id } }

    // MARK: Adding

    enum AddResult: Equatable {
        /// `droppedLink`: an address was given and was not one Nidus keeps,
        /// so only the words were saved.
        case added(InboxItem, droppedLink: Bool)
        /// The address is already in the inbox: not added again.
        case duplicate(InboxItem)
        /// No words and no usable address.
        case empty
    }

    /// Puts a thought and/or a link in the inbox. Words are cleaned and
    /// shortened; an address that isn't http(s) is dropped and the words
    /// kept; an address with no words gets the site's name.
    ///
    /// A save that carries an address adds nothing when an open item has the
    /// same page, or when any item saved from it is less than ten minutes old.
    /// Words alone always add.
    @discardableResult
    func add(text: String, link: String? = nil, assumingHTTPS: Bool = false,
             source: InboxItem.Source = .capture) -> AddResult {
        let words = InboxText.clean(text)
        let rawLink = link?.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = rawLink.flatMap { $0.isEmpty ? nil : InboxURL.clean($0, assumingHTTPS: assumingHTTPS) }
        let dropped = !(rawLink ?? "").isEmpty && address == nil
        guard !words.isEmpty || address != nil else { return .empty }

        let time = now()
        if let address, let key = InboxURL.key(for: address),
           let existing = items.first(where: { item in
               guard let other = item.url.flatMap(InboxURL.key(for:)), other == key else { return false }
               return !item.isCompleted || time.timeIntervalSince(item.createdAt) < Self.duplicateWindow
           }) {
            return .duplicate(existing)
        }
        let item = InboxItem(text: words.isEmpty ? InboxURL.displayText(for: address ?? "") : words,
                             url: address, source: source, createdAt: time)
        items.append(item)
        pruneExpired()
        save()
        return .added(item, droppedLink: dropped)
    }

    enum SaveLinkOutcome: Equatable, Sendable {
        case saved
        /// Already in the inbox; nothing was added.
        case duplicate
        /// The token is missing or wrong: not saved.
        case badToken
        /// Not an http(s) address: not saved.
        case notAWebAddress
    }

    /// What `nidus://save` asks for. The token is checked first, and a link
    /// without it does nothing at all. It saves the address and nothing else:
    /// it doesn't snooze, unblock, open or navigate, and has no way to.
    func saveFromBlockPage(url address: String, token: String) -> SaveLinkOutcome {
        guard InboxSaveToken.matches(token, in: directory) else { return .badToken }
        guard InboxURL.clean(address) != nil else { return .notAWebAddress }
        switch add(text: "", link: address, source: .blockedPage) {
        case .added: return .saved
        case .duplicate: return .duplicate
        case .empty: return .notAWebAddress
        }
    }

    // MARK: Changing

    /// Done, or open again. A completed item is deleted after 30 days.
    @discardableResult
    func setCompleted(_ id: InboxItem.ID, _ completed: Bool) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items[index].completedAt = completed ? now() : nil
        pruneExpired()
        save()
        return true
    }

    @discardableResult
    func delete(_ id: InboxItem.ID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items.remove(at: index)
        save()
        return true
    }

    /// Clear Inbox: every item, done or not, and the file. The block page's
    /// token stays: the pages already up would otherwise stop working.
    func clear() {
        items.removeAll()
        try? FileManager.default.removeItem(at: url)
        onChange?()
    }

    /// Deletes completed items past their 30 days, writes the file and tells
    /// the views when any went. Done on load and on every save; the Inbox page
    /// also calls it when it opens, for a Nidus that has been running a long
    /// time.
    @discardableResult
    func prune() -> Bool {
        guard pruneExpired() else { return false }
        save()
        return true
    }

    @discardableResult
    private func pruneExpired() -> Bool {
        let time = now()
        let before = items.count
        items.removeAll { item in
            guard let completed = item.completedAt else { return false }
            return time.timeIntervalSince(completed) >= Self.completedRetention
        }
        return items.count != before
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(File(items: items)) {
            try? data.write(to: url, options: .atomic)
        }
        onChange?()
    }
}
