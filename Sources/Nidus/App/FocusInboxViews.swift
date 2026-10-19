//
//  FocusInboxViews.swift
//  Nidus
//
//  The distraction inbox's surfaces: the popover's quiet row (Save a thought
//  while a session runs, Inbox · 3 whenever something is waiting), the Inbox
//  page in Settings (the list, the capture shortcut, how long things are
//  kept, Clear Inbox), and the line on the wrap-up card. The store is
//  Core/FocusInbox.swift and the capture panel is FocusCapture.swift.
//
//  Nothing here opens by itself. A link opens when its Open button is
//  pressed, and the inbox opens when you ask: not when focus ends.
//

import AppKit
import SwiftUI

extension NidusModel.Key {
    /// The capture shortcut, a `KeyShortcut`; absent or null is off.
    static let captureShortcut = "captureShortcut"
}

// MARK: - The model's side

extension NidusModel {
    nonisolated static let inboxPageID = "inbox"

    /// Opens the inbox file in Nidus's folder and registers the capture
    /// shortcut, if one is set. Called from `activate`.
    func startInbox(host: NidusHost) {
        let inbox = FocusInbox(directory: host.environment.containerDirectory)
        inbox.onChange = { [weak self] in self?.objectWillChange.send() }
        self.inbox = inbox
        capture.start(model: self)
    }

    /// Lets go of the shortcut. Called from `deactivate`.
    func stopInbox() {
        capture.stop()
        inbox = nil
    }

    /// Items not yet done.
    var inboxOpenCount: Int { inbox?.openCount ?? 0 }

    /// The global shortcut that opens the capture panel. Off until set.
    var captureShortcut: KeyShortcut? {
        get { preference(Key.captureShortcut, default: KeyShortcut?.none) }
        set {
            setPreference(newValue, Key.captureShortcut)
            capture.apply(newValue)
            objectWillChange.send()
        }
    }

    /// The capture panel. The popover closes first, so it isn't left open
    /// under it. Never touches the session.
    func showCapturePanel() {
        menuBarItem?.closePopover()
        capture.show(model: self)
    }

    /// The inbox in Settings, from the popover or the wrap-up card.
    func openInbox() {
        menuBarItem?.closePopover()
        host?.workspace.openSettingsPage(Self.inboxPageID, title: "Inbox")
    }

    @discardableResult
    func saveToInbox(text: String, link: String) -> FocusInbox.AddResult {
        inbox?.add(text: text, link: link, assumingHTTPS: true, source: .capture) ?? .empty
    }

    /// An item's Open button: the one way an address in the inbox is opened.
    /// It is read again here, so what was never an http(s) address is not
    /// handed to the system whatever the file says.
    func openInboxItem(_ id: InboxItem.ID) {
        guard let address = inbox?.item(id)?.url, let clean = InboxURL.clean(address), let url = URL(string: clean) else { return }
        inboxURLOpener(url)
    }

    func setInboxItem(_ id: InboxItem.ID, completed: Bool) { inbox?.setCompleted(id, completed) }
    func deleteInboxItem(_ id: InboxItem.ID) { inbox?.delete(id) }
    func clearInbox() { inbox?.clear() }

    /// How many were saved since a session began, for the wrap-up card.
    func savedForLater(since start: Date) -> Int { inbox?.count(since: start) ?? 0 }

    /// "3 saved for later", or nil for none.
    static func savedForLaterText(_ count: Int) -> String? {
        count > 0 ? "\(count) saved for later" : nil
    }
}

// MARK: - The popover's row

/// One quiet line under the popover's controls: "Save a thought" while a
/// session runs (it opens the capture panel), and "Inbox · 3" whenever items
/// are waiting. Draws nothing otherwise, so the popover stays as compact as it
/// was. Neither button changes the session.
struct FocusInboxRow: View {
    @ObservedObject var model: NidusModel

    static func isVisible(isActive: Bool, openCount: Int) -> Bool { isActive || openCount > 0 }

    var body: some View {
        if Self.isVisible(isActive: model.isActive, openCount: model.inboxOpenCount) {
            HStack(spacing: NidusSpacing.sm) {
                if model.isActive {
                    Button(action: model.showCapturePanel) {
                        Label("Save a thought", systemImage: "square.and.pencil")
                    }
                    .help("Put a thought or link in your inbox. Your session carries on.")
                    .accessibilityLabel("Save a thought")
                    .accessibilityHint("Opens a small box to save a thought for later. The session is not affected.")
                }
                Spacer(minLength: NidusSpacing.sm)
                if model.inboxOpenCount > 0 {
                    Button(action: model.openInbox) {
                        Label("Inbox \u{00B7} \(model.inboxOpenCount)", systemImage: "tray")
                    }
                    .help("Open your inbox in Settings")
                    .accessibilityLabel("Inbox, \(model.inboxOpenCount) saved for later")
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - The wrap-up card's line

/// "3 saved for later" and a button that opens the inbox. A row of the
/// wrap-up card; nothing opens until the button is pressed.
struct FocusSavedForLaterRow: View {
    let count: Int
    let open: () -> Void

    var body: some View {
        HStack(spacing: NidusSpacing.md) {
            Image(systemName: "tray")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AdaptiveColors.surfaceSecondaryText)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(verbatim: NidusModel.savedForLaterText(count) ?? "")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AdaptiveColors.surfacePrimaryText)
                .lineLimit(1)
            Spacer(minLength: NidusSpacing.sm)
            Button("Open inbox", action: open)
                .buttonStyle(.bordered)
                .fixedSize()
                .accessibilityLabel("Open the inbox in Settings")
        }
    }
}

// MARK: - General's link

extension FocusGeneralPage {
    /// A way into the Inbox page from General, with where it stands.
    var inboxSection: some View {
        NidusSettingsSection {
            settingsSectionHeader("Distraction inbox",
                                  detail: "Set a thought or a link aside during a session, and deal with it afterwards.")
        } content: {
            NidusSettingsCard {
                NidusSettingsPageLink("Inbox", subtitle: inboxSummary, page: NidusModel.inboxPageID) {
                    CategoryTile(symbol: "tray")
                }
            }
        }
    }

    private var inboxSummary: String {
        var parts: [String] = []
        let open = model.inboxOpenCount
        parts.append(open == 0 ? "Nothing waiting" : "\(open) waiting")
        parts.append(model.captureShortcut.map { "Capture: \($0.display)" } ?? "Capture shortcut off")
        return parts.joined(separator: " \u{00B7} ")
    }
}

// MARK: - The Inbox page

struct FocusInboxPage: View {
    @ObservedObject var model: NidusModel
    @State private var confirmingClear = false
    @State private var showsDone = false

    var body: some View {
        let open = model.inbox?.openItems ?? []
        let done = model.inbox?.completedItems ?? []
        NidusSettingsPage {
            NidusSettingsSection {
                settingsSectionHeader("Saved for later",
                                      detail: "Nidus never fetches a page or opens a link for you. Open does that, when you press it.")
            } content: {
                NidusSettingsCard {
                    if open.isEmpty {
                        Text(done.isEmpty ? "Nothing here. Put a thought down during a session and it waits for you here."
                                          : "Nothing waiting.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, NidusSpacing.sm)
                    } else {
                        ForEach(open) { row($0) }
                    }
                    NidusControlRow(title: "Save a thought") {
                        Button("Write\u{2026}", action: model.showCapturePanel)
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Save a thought")
                    }
                }
            }

            if !done.isEmpty {
                NidusSettingsSection {
                    settingsSectionHeader("Done")
                } content: {
                    NidusSettingsCard {
                        DisclosureGroup(isExpanded: $showsDone) {
                            ForEach(done) { row($0) }
                        } label: {
                            Text("\(done.count) done")
                        }
                    }
                }
            }

            NidusSettingsSection {
                settingsSectionHeader("Capture shortcut")
            } content: {
                NidusSettingsCard {
                    NidusControlRow(title: "Shortcut",
                                      infoTip: "Opens a small box to save a thought or a link, from any app, without leaving what you're doing. Off until you set one.") {
                        ShortcutRecorder(shortcut: model.binding(\.captureShortcut))
                    }
                    if model.captureShortcut != nil, model.capture.shortcutIsRefused {
                        Label("Another app is using that combination. Choose a different one.",
                              systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }

            NidusSettingsSection {
                settingsSectionHeader("Keeping things")
            } content: {
                NidusSettingsCard {
                    Text("Items you finish are deleted 30 days after you finish them. Items you haven't finished stay until you delete them. Everything is kept in a file on this Mac. A page saved from the block page is kept as its address, even if it was open in a private window.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    NidusControlRow(title: "Clear Inbox",
                                      infoTip: "Deletes every item, finished or not.") {
                        Button("Clear\u{2026}", role: .destructive) { confirmingClear = true }
                            .buttonStyle(.bordered)
                            .disabled(open.isEmpty && done.isEmpty)
                    }
                }
            }
        }
        .confirmationDialog("Clear your inbox?", isPresented: $confirmingClear) {
            Button("Clear Inbox", role: .destructive, action: model.clearInbox)
        } message: {
            Text("Every saved thought and link, finished or not, is deleted from this Mac. This can't be undone.")
        }
        // A Nidus left running for weeks still lets go of what is 30 days old.
        .onAppear { model.inbox?.prune() }
    }

    private func row(_ item: InboxItem) -> some View {
        InboxItemRow(item: item,
                     toggle: { model.setInboxItem(item.id, completed: !item.isCompleted) },
                     open: { model.openInboxItem(item.id) },
                     delete: { model.deleteInboxItem(item.id) })
    }
}

/// One item: a check to finish it, its words, its address if it has one (in
/// full, so Open is no surprise), when and from where, and Open and Delete.
/// All text is drawn verbatim: nothing a person pasted is read as markup.
struct InboxItemRow: View {
    let item: InboxItem
    let toggle: () -> Void
    let open: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: NidusSpacing.md) {
            Button(action: toggle) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(item.isCompleted ? AnyShapeStyle(FocusPalette.clay) : AnyShapeStyle(.secondary))
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(item.isCompleted ? "Mark as not done" : "Mark as done")
            .accessibilityLabel(item.isCompleted ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.text)
                    .strikethrough(item.isCompleted)
                    .foregroundStyle(item.isCompleted ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let url = item.url {
                    Text(verbatim: url)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(verbatim: Self.caption(for: item))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: NidusSpacing.md)
            if item.url != nil {
                Button("Open", action: open)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Open this link in your browser")
                    .accessibilityLabel("Open the link: \(item.text)")
            }
            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Delete")
            .accessibilityLabel("Delete: \(item.text)")
        }
        .accessibilityElement(children: .contain)
    }

    /// "Block page, Oct 17 at 2:14 PM", or "Done Oct 17 at 2:14 PM".
    static func caption(for item: InboxItem) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        if let done = item.completedAt { return "Done " + done.formatted(style) }
        let from = item.source == .blockedPage ? "Block page" : "Thought"
        return from + " \u{00B7} " + item.createdAt.formatted(style)
    }
}
