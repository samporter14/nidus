//
//  BrickCompanion.swift
//  Nidus
//
//  An opt-in, local request to choose a Mac session. The sender reports an
//  intention to focus; Nidus cannot verify the phone's Brick state.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BrickSignal: Codable, Equatable, Sendable {
    let version: Int
    let id: String
    let timestamp: String
    let event: String

    static let kind = "phone_focus_requested"
    static let clearedKind = "phone_focus_cleared"
    static let maxBytes = 4096
    static let maxAge: TimeInterval = 120
    static let futureAllowance: TimeInterval = 15

    var date: Date? {
        let whole = ISO8601DateFormatter()
        if let date = whole.date(from: timestamp) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: timestamp)
    }

    var hasValidStructure: Bool {
        guard version == 1, (event == Self.kind || event == Self.clearedKind), (8...80).contains(id.utf8.count),
              id.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) ||
                  (97...122).contains(byte) || byte == 45 || byte == 95
              }), date != nil else { return false }
        return true
    }

    func isValid(at now: Date) -> Bool {
        guard hasValidStructure, let date else { return false }
        let age = now.timeIntervalSince(date)
        return age >= -Self.futureAllowance && age <= Self.maxAge
    }

    static func parse(_ data: Data) -> BrickSignal? {
        guard !data.isEmpty, data.count <= maxBytes else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func parse(_ url: URL) -> BrickSignal? {
        guard url.scheme?.lowercased() == "nidus", url.host?.lowercased() == "brick",
              url.absoluteString.utf8.count <= 1024,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = parts.queryItems, items.count == 2,
              Set(items.map(\.name)) == Set(["id", "timestamp"]),
              let id = items.first(where: { $0.name == "id" })?.value,
              let timestamp = items.first(where: { $0.name == "timestamp" })?.value else { return nil }
        return Self(version: 1, id: id, timestamp: timestamp, event: kind)
    }

    /// Shared gate for both transports. A busy valid id is still consumed,
    /// so it cannot return later as a surprise offer.
    func disposition(at now: Date, ledger: BrickReplayLedger, idle: Bool) -> Disposition {
        guard isValid(at: now), let date, date > ledger.floor,
              !ledger.entries.contains(where: { $0.id == id }) else { return .ignore }
        if event == Self.clearedKind {
            // A delayed unbrick observation must not dismiss a newer request.
            guard date >= (ledger.entries.map(\.date).max() ?? .distantPast) else { return .ignore }
            return .clear
        }
        return idle ? .offer : .consume
    }

    enum Disposition: Equatable { case ignore, consume, offer, clear }
}

struct BrickReplayLedger: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let id: String
        let date: Date
    }
    var entries: [Entry] = []
    var floor: Date = .distantPast

    mutating func record(_ signal: BrickSignal, now: Date) {
        guard let date = signal.date else { return }
        // Once the phone reports Brick off, an older request delivered later
        // cannot recreate an offer. This does not affect a running session.
        if signal.event == BrickSignal.clearedKind { floor = max(floor, date) }
        entries.removeAll { now.timeIntervalSince($0.date) > BrickSignal.maxAge }
        entries.append(Entry(id: signal.id, date: date))
        // If a local source floods requests, evicted timestamps become a
        // lower bound. This still rejects their replay during freshness.
        if entries.count > 4096 {
            entries.sort { $0.date < $1.date }
            let overflow = entries.count - 4096
            floor = max(floor, entries[overflow - 1].date)
            entries.removeFirst(overflow)
        }
    }
}

struct BrickPendingOffer: Equatable, Sendable {
    let signal: BrickSignal

    func isActionable(at now: Date, enabled: Bool, idle: Bool) -> Bool {
        enabled && idle && signal.isValid(at: now)
    }

    @discardableResult
    func chooseSession(at now: Date, enabled: Bool, idle: Bool, openComposer: () -> Void) -> Bool {
        guard isActionable(at: now, enabled: enabled, idle: idle) else { return false }
        openComposer()
        return true
    }
}

struct BrickFileGate {
    private var baselineNeeded = true
    private var fingerprint: Data?

    enum Result: Equatable {
        case baseline(BrickSignal?)
        case changed(BrickSignal?)
        case unchanged
    }

    mutating func reset() {
        baselineNeeded = true
        fingerprint = nil
    }

    mutating func ingest(_ data: Data) -> Result {
        if baselineNeeded {
            baselineNeeded = false
            fingerprint = data
            return .baseline(BrickSignal.parse(data))
        }
        guard fingerprint != data else { return .unchanged }
        fingerprint = data
        return .changed(BrickSignal.parse(data))
    }
}

enum BrickFileReader {
    struct Result: Sendable {
        let data: Data?
        let name: String
        let status: String
        var refreshedBookmark: Data? = nil
    }

    static func read(bookmark: Data) -> Result {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return Result(data: nil, name: "", status: "File access expired. Choose the file again.")
        }
        let name = url.lastPathComponent
        guard url.startAccessingSecurityScopedResource() else {
            return Result(data: nil, name: name, status: "File access expired. Choose the file again.")
        }
        defer { url.stopAccessingSecurityScopedResource() }
        var result = readFile(at: url)
        // Save File may atomically replace the selected path. Foundation then
        // reports the old bookmark as stale while still resolving the new
        // readable file. Renew it without re-baselining this request.
        if stale {
            result.refreshedBookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                              includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        return result
    }

    /// File I/O is bounded before decoding and happens on a detached task.
    /// This direct entry point also lets tests exercise a temporary file.
    static func readFile(at url: URL) -> Result {
        let name = url.lastPathComponent
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return Result(data: nil, name: name, status: "The selected file is unavailable or is not a regular file.")
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return Result(data: nil, name: name, status: "Cannot read the selected file right now.")
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: BrickSignal.maxBytes + 1) else {
            return Result(data: nil, name: name, status: "Cannot read the selected file right now.")
        }
        guard data.count <= BrickSignal.maxBytes else {
            return Result(data: nil, name: name, status: "Signal file exceeds 4 KB.")
        }
        return Result(data: data, name: name,
                      status: BrickSignal.parse(data) == nil ? "Waiting for a valid JSON request." : "Checking for new requests.")
    }
}

@MainActor
final class BrickCompanion {
    private weak var model: NidusModel?
    private var pollTask: Task<Void, Never>?
    private var fileGate = BrickFileGate()
    private var offerExpiryTask: Task<Void, Never>?

    func activate(_ model: NidusModel) {
        self.model = model
        fileGate.reset()
        refresh()
    }

    func deactivate() {
        pollTask?.cancel()
        pollTask = nil
        offerExpiryTask?.cancel()
        offerExpiryTask = nil
        model = nil
    }

    func refresh() {
        pollTask?.cancel()
        pollTask = nil
        guard let model, model.brickEnabled else {
            model?.dismissBrickOffer()
            fileGate.reset()
            return
        }
        guard !model.brickFileBookmark.isEmpty else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.readSelectedFile()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func selectedNewFile() {
        model?.dismissBrickOffer()
        fileGate.reset()
        refresh()
    }

    func cancelOfferExpiry() {
        offerExpiryTask?.cancel()
        offerExpiryTask = nil
    }

    func receive(_ signal: BrickSignal, now: Date = Date()) {
        guard let model, model.brickEnabled else { return }
        model.expireBrickOffer(now: now)
        // Remember even a busy request so it cannot appear when a session
        // or break finishes. Every request has its own id.
        let disposition = signal.disposition(at: now, ledger: model.brickReplayLedger,
                                             idle: model.canStartNew)
        guard disposition != .ignore else { return }
        var ledger = model.brickReplayLedger
        ledger.record(signal, now: now)
        model.brickReplayLedger = ledger
        if disposition == .clear {
            model.dismissBrickOffer()
            return
        }
        guard disposition == .offer else { return }
        model.brickOffer = BrickPendingOffer(signal: signal)
        model.presentBrickOfferHUD()
        offerExpiryTask?.cancel()
        offerExpiryTask = Task { [weak model] in
            let remaining = max(0, signal.date!.addingTimeInterval(BrickSignal.maxAge).timeIntervalSince(Date()))
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            model?.expireBrickOffer()
        }
    }

    private func readSelectedFile() async {
        guard let model, model.brickEnabled else { return }
        model.expireBrickOffer()
        let bookmark = model.brickFileBookmark
        let result = await Task.detached { BrickFileReader.read(bookmark: bookmark) }.value
        guard !Task.isCancelled, model.brickEnabled, model.brickFileBookmark == bookmark else { return }
        if let refreshed = result.refreshedBookmark {
            model.host?.preferences.setValueQuietly(refreshed, forKey: NidusModel.Key.brickFileBookmark)
        }
        model.brickFileName = result.name
        model.brickFileStatus = result.status
        guard let data = result.data else { return }
        // A selected file's existing value is a baseline on launch, enable,
        // or selection. Subsequent identical reads are inert.
        switch fileGate.ingest(data) {
        case .baseline(let signal):
            if let signal, signal.isValid(at: Date()),
               signal.disposition(at: Date(), ledger: model.brickReplayLedger, idle: false) != .ignore {
                var ledger = model.brickReplayLedger
                ledger.record(signal, now: Date())
                model.brickReplayLedger = ledger
            }
        case .changed(let signal):
            if let signal { receive(signal) }
        case .unchanged: break
        }
    }
}

extension NidusModel.Key {
    static let brickEnabled = "brickCompanionEnabled"
    // Legacy saved-setup preference is left in existing defaults but ignored.
    static let brickFileBookmark = "brickCompanionFileBookmark"
    static let brickReplayLedger = "brickCompanionReplayLedger"
}

extension NidusModel {
    static let brickHUDID = "focus.brick-offer"

    var brickEnabled: Bool {
        get { preference(Key.brickEnabled, default: false) }
        set {
            setPreference(newValue, Key.brickEnabled)
            if !newValue { dismissBrickOffer() }
            brickCompanion.refresh()
        }
    }

    var brickFileBookmark: Data {
        get { preference(Key.brickFileBookmark, default: Data()) }
        set {
            setPreference(newValue, Key.brickFileBookmark)
            brickFileName = ""
            brickFileStatus = newValue.isEmpty ? "No file selected." : "Checking selected file…"
            brickCompanion.selectedNewFile()
        }
    }

    var brickReplayLedger: BrickReplayLedger {
        get { preference(Key.brickReplayLedger, default: BrickReplayLedger()) }
        set { setPreference(newValue, Key.brickReplayLedger) }
    }

    var currentBrickOffer: BrickPendingOffer? {
        guard let offer = brickOffer,
              offer.isActionable(at: Date(), enabled: brickEnabled, idle: canStartNew) else { return nil }
        return offer
    }

    func expireBrickOffer(now: Date = Date()) {
        if let offer = brickOffer,
           !offer.isActionable(at: now, enabled: brickEnabled, idle: canStartNew) {
            dismissBrickOffer()
        }
    }

    func dismissBrickOffer() {
        brickOffer = nil
        brickCompanion.cancelOfferExpiry()
        host?.hud.dismiss(id: Self.brickHUDID)
    }

    /// The Brick action only opens the regular composer. Its existing draft
    /// and Start button remain the authority for the session that follows.
    @discardableResult
    func chooseBrickSession(id: String? = nil, openComposer: (() -> Void)? = nil) -> Bool {
        guard let offer = currentBrickOffer else { dismissBrickOffer(); return false }
        guard id == nil || id == offer.signal.id else { return false }
        return offer.chooseSession(at: Date(), enabled: brickEnabled, idle: canStartNew) {
            dismissBrickOffer()
            if let openComposer { openComposer() } else { showPopover() }
        }
    }

    func chooseBrickFile() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.json]
        picker.canChooseDirectories = false
        picker.canChooseFiles = true
        picker.allowsMultipleSelection = false
        picker.prompt = "Use file"
        guard picker.runModal() == .OK, let url = picker.url,
              let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        brickFileBookmark = bookmark
    }

    func clearBrickFile() { brickFileBookmark = Data() }

    func presentBrickOfferHUD() {
        guard let host, (!host.hud.isShowing || host.hud.isShowing(id: Self.brickHUDID)),
              let offer = currentBrickOffer else { return }
        let request = HUDRequest(id: Self.brickHUDID, duration: 12,
                                 accessibilityLabel: "From your phone. Ready to focus? Choose session.") { [weak self] in
            BrickOfferCard(onChoose: { _ = self?.chooseBrickSession(id: offer.signal.id) },
                           onDismiss: { self?.dismissBrickOffer() })
        }
        host.hud.present(request)
    }
}

struct BrickOfferCard: View {
    let onChoose: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top, spacing: 12) {
                SolanumTile(symbol: "iphone.gen3", size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Overline("From your phone")
                    Text("Ready to focus?")
                        .font(Solanum.serif(23).weight(.semibold))
                        .foregroundStyle(Solanum.ink)
                }
                Spacer(minLength: 0)
            }
            Text("Choose your goal, setup, and duration.")
                .font(.system(size: 13))
                .foregroundStyle(Solanum.inkMuted)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Not now", action: onDismiss)
                    .buttonStyle(SolanumButtonStyle())
                Button("Choose session", action: onChoose)
                    .buttonStyle(SolanumPrimaryButtonStyle())
            }
        }
        .padding(16)
        .accessibilityElement(children: .contain)
    }
}

struct BrickPopoverRow: View {
    @ObservedObject var model: NidusModel

    var body: some View {
        if model.currentBrickOffer != nil {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .center, spacing: 10) {
                    SolanumTile(symbol: "iphone.gen3", size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("From your phone")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Solanum.ink)
                        Text("Ready to focus?")
                            .font(.system(size: 12))
                            .foregroundStyle(Solanum.inkMuted)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Not now") { model.dismissBrickOffer() }
                        .buttonStyle(SolanumButtonStyle())
                    Button("Choose session") { _ = model.chooseBrickSession() }
                        .buttonStyle(SolanumPrimaryButtonStyle())
                }
            }
            .padding(13)
            .background(Solanum.clay.opacity(0.08), in: .rect(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Solanum.clay.opacity(0.30)))
            .accessibilityElement(children: .contain)
        }
    }
}

struct BrickSettingsSection: View {
    @ObservedObject var model: NidusModel

    var body: some View {
        NidusSettingsSection {
            settingsSectionHeader("Brick companion", detail: "A phone focus request can open the session chooser here.")
        } content: {
            NidusSettingsCard {
                NidusToggleRow(title: "Offer to choose a session for phone focus requests",
                               subtitle: "Requests from a chosen file or nidus://brick link. Nidus cannot verify whether your phone is bricked.",
                               isOn: Binding(get: { model.brickEnabled }, set: { model.brickEnabled = $0 }))
                if model.brickEnabled {
                    NidusControlRow(title: "Phone request file") {
                        Button(model.brickFileBookmark.isEmpty ? "Choose JSON file…" : "Change JSON file…") {
                            model.chooseBrickFile()
                        }
                    }
                    if !model.brickFileBookmark.isEmpty {
                        NidusControlRow(title: model.brickFileName.isEmpty ? "Selected file" : model.brickFileName) {
                            Button("Remove", action: model.clearBrickFile)
                        }
                        Label(model.brickFileStatus, systemImage: "doc.text")
                            .font(.caption)
                            .foregroundStyle(Solanum.inkMuted)
                    }
                    Text("The file can live in iCloud Drive. Nidus checks it while this is on. Existing requests are ignored when you enable, select, or relaunch. Choose session opens the normal focus controls; you start there.")
                        .font(.caption)
                        .foregroundStyle(Solanum.inkMuted)
                }
            }
        }
    }
}
