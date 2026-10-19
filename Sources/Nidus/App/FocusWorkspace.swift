//
//  FocusWorkspace.swift
//  Nidus
//
//  Saved workspaces: what a setup opens and runs besides blocking. The pure
//  parts live here so they are tested without a model: editing a setup's
//  documents, folders and pages, the pages its own rules would block, and
//  the one-line summaries the setup page shows. The model's part is saying
//  how a start went: one card that names the setup, what could not be
//  opened, and any page its own rules block.
//
//  Start never waits on any of it. A session starts with whatever opens; a
//  page its rules block opens and is replaced by the block page like any
//  other, and the setup page and the card say so beforehand and after.
//

import SwiftUI

// MARK: - Editing the list

extension FocusSetup {
    /// Adds documents, folders or pages, skipping what is already there (the
    /// same file, the same address) and stopping at the limit. Returns how
    /// many were added.
    @discardableResult
    mutating func add(_ new: [WorkspaceResource]) -> Int {
        var added = 0
        for resource in new where resources.count < Self.resourceLimit {
            guard !resources.contains(where: { $0.isSameThing(as: resource) }) else { continue }
            resources.append(resource)
            added += 1
        }
        return added
    }

    /// A resource chosen again keeps its place in the list. Chosen again as
    /// something already in the list, it is dropped instead of doubled.
    mutating func replace(_ id: WorkspaceResource.ID, with chosen: WorkspaceResource) {
        guard let index = resources.firstIndex(where: { $0.id == id }) else { return }
        if resources.contains(where: { $0.id != id && $0.isSameThing(as: chosen) }) {
            resources.remove(at: index)
        } else {
            resources[index] = chosen
        }
    }

    var documents: [WorkspaceResource] { resources.filter { $0.kind != .webPage } }
    var pages: [WorkspaceResource] { resources.filter { $0.kind == .webPage } }

    /// Whether it opens or runs anything of its own.
    var hasWorkspace: Bool {
        launchApps != nil || startShortcut != nil || endShortcut != nil || !websiteExceptions.isEmpty || !resources.isEmpty
    }
}

extension WorkspaceResource {
    /// The same file or the same address, whatever it is called.
    func isSameThing(as other: WorkspaceResource) -> Bool {
        if kind == .webPage || other.kind == .webPage {
            guard kind == other.kind, let a = url, let b = other.url else { return false }
            return a == b
        }
        guard let a = path, let b = other.path else { return false }
        return URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
    }
}

// MARK: - Things its own rules block

/// Something a setup opens that the setup's own blocking rules would block:
/// a web page its websites cover, or a document whose app its apps cover.
struct WorkspaceConflict: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case page
        /// A document or folder that opens in this app.
        case app(BlockedApp)
    }

    var kind: Kind
    var resourceID: WorkspaceResource.ID
    /// How the resource is listed: "reviewer.org/guide", "Aims.pdf".
    var page: String
    /// The page's address; the file's path for a document.
    var address: String
    /// The categories whose websites (or apps) cover it; none known in an
    /// allow list.
    var blockedBy: [String]
    var isAllowList: Bool
    /// The exception that would let exactly this page through, when one can
    /// be made. Never offered for an allow list, which has no exceptions.
    var fix: WebsiteException?

    var id: WorkspaceResource.ID { resourceID }

    /// The app a document opens in, for an app conflict.
    var app: BlockedApp? {
        if case .app(let app) = kind { return app }
        return nil
    }

    /// Whether there is something to press: an exception for a page, and for
    /// an app, adding it to the setup's apps to open (which no session blocks).
    var hasFix: Bool { app != nil || fix != nil }

    /// "Allow only this page", "Add Preview to Apps to open".
    var fixTitle: String {
        guard let app else { return "Allow only this page" }
        return "Add \(app.name) to Apps to open"
    }

    /// The same on the card, where the sentence beside it already names the app.
    var cardFixTitle: String { app == nil ? fixTitle : "Add to Apps to open" }

    /// What the card says once it is done.
    var fixDone: String {
        app == nil ? "Allowed from the next start" : "Added to Apps to open from the next start"
    }

    /// "Blocked by Video", "Not on the allow list", "Opens in Preview, which is blocked".
    var reason: String {
        if let app { return "Opens in \(app.name), which is \(isAllowList ? "not allowed" : "blocked")" }
        if isAllowList { return "Not on the allow list" }
        guard !blockedBy.isEmpty else { return "Blocked by this setup\u{2019}s rules" }
        return "Blocked by \(WorkspaceReport.list(blockedBy))"
    }

    /// The line a row starts with: "reviewer.org/guide is blocked".
    var rowTitle: String {
        app == nil ? "\(page) is blocked" : "\(page) opens in a blocked app"
    }

    /// One sentence for the card: "reviewer.org/guide is blocked by Video.",
    /// "Aims.pdf opens in Preview, which this setup blocks."
    var sentence: String {
        if let app {
            return "\(page) opens in \(app.name), which this setup \(isAllowList ? "doesn\u{2019}t allow" : "blocks")."
        }
        if isAllowList { return "\(page) isn\u{2019}t on the allow list." }
        guard !blockedBy.isEmpty else { return "\(page) is blocked by this setup\u{2019}s rules." }
        return "\(page) is blocked by \(WorkspaceReport.list(blockedBy))."
    }

    /// The card's sentence and what the fix does: it applies from the next
    /// start, because a running session keeps what it started with.
    var cardSentence: String {
        if app != nil { return sentence + " Adding it applies from the next start." }
        return sentence + (fix != nil ? " Allowing it applies from the next start." : " It opens, then the block page replaces it.")
    }

    /// What the setup page says under it.
    var explanation: String {
        if let app {
            return "\(sentence) It still opens when the session starts, then \(app.name) is blocked like any other app."
        }
        let tail = isAllowList
            ? "Only what the allow list names is let through."
            : "It still opens when the session starts, then the block page replaces it."
        return "\(reason). \(tail)"
    }
}

enum WorkspaceConflicts {
    /// The pages and documents among `resources` that these rules would
    /// block. The rules are the ones a session enforces: the same
    /// `WebsiteRule` the sweep uses (exceptions included) and the same app
    /// rule `AppBlocker` uses (the apps a session opens are never blocked),
    /// so what is shown is what happens.
    ///
    /// `apps` are the blocked apps in a block list and the allowed ones in an
    /// allow list, as a plan holds them; `openedBy` says which app opens each
    /// document (see `openers`), and a document it doesn't name is skipped.
    static func find(in resources: [WorkspaceResource], mode: SessionPlan.Mode, websites: [String],
                     exceptions: [WebsiteException], categories: [FocusCategory],
                     apps: [String] = [], launchApps: [String] = [],
                     openedBy: [WorkspaceResource.ID: BlockedApp] = [:]) -> [WorkspaceConflict] {
        let rule = WebsiteRule(mode: mode == .block ? .block : .allow, domains: websites,
                               exceptions: mode == .block ? exceptions : [])
        let appMode: AppBlocker.Mode = mode == .block ? .block(Set(apps).subtracting(launchApps))
                                                      : .allow(Set(apps).union(launchApps))
        return resources.compactMap { resource in
            switch resource.kind {
            case .webPage:
                guard let address = resource.url, WorkspaceResource.openableAddress(address) != nil,
                      rule.blocks(address) else { return nil }
                let by = mode == .block
                    ? categories.filter { WebsiteRule(mode: .block, domains: $0.websites).blocks(address) }.map(\.name)
                    : []
                return WorkspaceConflict(kind: .page, resourceID: resource.id, page: resource.shownName, address: address,
                                         blockedBy: by, isAllowList: mode == .allow,
                                         fix: mode == .block ? exactException(for: address) : nil)
            case .document, .folder:
                guard let app = openedBy[resource.id], AppBlocker.isBlocked(app.bundleID, under: appMode) else { return nil }
                let by = mode == .block
                    ? categories.filter { category in category.apps.contains { $0.bundleID == app.bundleID } }.map(\.name)
                    : []
                return WorkspaceConflict(kind: .app(app), resourceID: resource.id, page: resource.shownName,
                                         address: resource.path ?? "", blockedBy: by, isAllowList: mode == .allow, fix: nil)
            }
        }
    }

    /// Which app opens each document and folder that can be found. Only
    /// asks; nothing is opened. Read once when a page appears or a start
    /// happens, not while a page draws.
    static func openers(for resources: [WorkspaceResource], launcher: WorkspaceLauncher,
                        finder: any DefaultAppFinding) -> [WorkspaceResource.ID: BlockedApp] {
        var found: [WorkspaceResource.ID: BlockedApp] = [:]
        for resource in resources where resource.kind != .webPage {
            if case .file(let url, _) = launcher.locate(resource), let app = finder.appToOpen(url) { found[resource.id] = app }
        }
        return found
    }

    /// The exception for exactly this page: its host and path, and the query
    /// parameters that identify it (tracking ones left out). Only if it does
    /// let this address through.
    static func exactException(for address: String) -> WebsiteException? {
        guard case .success(let draft) = WebsiteException.draft(from: address, kind: .exact),
              WebsiteExceptionMatcher([draft.exception]).allows(address) else { return nil }
        return draft.exception
    }

    /// Each exception once, in order.
    static func merged(_ lists: [[WebsiteException]]) -> [WebsiteException] {
        var all: [WebsiteException] = []
        for exception in lists.joined() where !all.contains(exception) { all.append(exception) }
        return all
    }
}

extension FocusSetup {
    /// Pages and documents this setup opens that its own categories (or allow
    /// list) block, judged as a session started from it would be: the live
    /// categories' websites and apps, their exceptions and the setup's own.
    /// A setup with no apps of its own opens Settings' (`settingsLaunchApps`),
    /// and those are never blocked. `openedBy` is what `openers` found.
    func conflicts(in categories: [FocusCategory], openedBy: [WorkspaceResource.ID: BlockedApp] = [:],
                   settingsLaunchApps: [BlockedApp] = []) -> [WorkspaceConflict] {
        let live = categories.filter { liveCategoryIDs(in: categories).contains($0.id) }
        let websites = live.flatMap(\.websites)
        let exceptions = WorkspaceConflicts.merged([live.flatMap(\.websiteExceptions), websiteExceptions])
        return WorkspaceConflicts.find(in: resources, mode: mode, websites: websites, exceptions: exceptions,
                                       categories: live, apps: live.flatMap { $0.apps.map(\.bundleID) },
                                       launchApps: (launchApps ?? settingsLaunchApps).map(\.bundleID), openedBy: openedBy)
    }

    /// The fix for a conflict, for the setup's next start: lets exactly that
    /// page through, or adds the app to the setup's own apps to open (which
    /// no session blocks). A setup that used Settings' apps keeps them: its
    /// own list starts from Settings'. False when there is nothing to add or
    /// it is already there.
    @discardableResult
    mutating func allow(_ conflict: WorkspaceConflict, settingsLaunchApps: [BlockedApp] = []) -> Bool {
        if let app = conflict.app {
            var apps = launchApps ?? settingsLaunchApps
            guard !apps.contains(where: { $0.bundleID == app.bundleID }) else { return false }
            apps.append(app)
            launchApps = apps
            return true
        }
        guard let fix = conflict.fix, !websiteExceptions.contains(fix) else { return false }
        websiteExceptions.append(fix)
        return true
    }
}

extension SessionPlan {
    /// Pages and documents this session opened that it blocks, from what it
    /// committed to when it started. `categories` only names them.
    func workspaceConflicts(categories: [FocusCategory],
                            openedBy: [WorkspaceResource.ID: BlockedApp] = [:]) -> [WorkspaceConflict] {
        let named = categories.filter { !Set($0.websites).isDisjoint(with: websites) || !Set($0.apps.map(\.bundleID)).isDisjoint(with: apps) }
        return WorkspaceConflicts.find(in: resources, mode: mode, websites: websites, exceptions: websiteExceptions,
                                       categories: named, apps: apps, launchApps: launchApps, openedBy: openedBy)
    }
}

// MARK: - One-line summaries

extension FocusSetup {
    /// "Xcode, Zotero and 1 more", the way a collapsed row reads.
    static func names(_ names: [String]) -> String { WorkspaceReport.list(names) }

    var appsSummary: String {
        guard let launchApps else { return "Uses Settings" }
        return launchApps.isEmpty ? "None" : Self.names(launchApps.map(\.name))
    }

    var documentsSummary: String {
        let documents = self.documents
        return documents.isEmpty ? "None" : Self.names(documents.map(\.shownName))
    }

    var pagesSummary: String {
        let pages = self.pages
        return pages.isEmpty ? "None" : Self.names(pages.map(\.shownName))
    }

    /// "Uses Settings", "None", or what each end does.
    var shortcutsSummary: String {
        if startShortcut == nil, endShortcut == nil { return "Uses Settings" }
        if startShortcut == "", endShortcut == "" { return "None" }
        func label(_ name: String?) -> String { name.map { $0.isEmpty ? "none" : $0 } ?? "Settings" }
        return "On start: \(label(startShortcut)), on end: \(label(endShortcut))"
    }

    var exceptionsSummary: String {
        websiteExceptions.isEmpty ? "None added" : "\(websiteExceptions.count) \(websiteExceptions.count == 1 ? "page" : "pages")"
    }
}

// MARK: - Project and break summaries

extension FocusSetup {
    /// "Uses the popover's", "No project", or the project's name.
    func projectSummary(in projects: [FocusProject]) -> String {
        switch project {
        case nil: return "Uses the popover\u{2019}s"
        case .noProject: return "No project"
        case .project(let id): return ProjectLabel.of(id: id, storedName: nil, in: projects)?.text ?? "No project"
        }
    }

    /// "Uses Settings", "No break" or the length.
    var breakSummary: String {
        guard let breakMinutes else { return "Uses Settings" }
        return breakMinutes == 0 ? "No break" : FocusFormat.duration(minutes: breakMinutes)
    }

    /// "Uses Settings", "Nothing blocked", or what stays blocked.
    func breakRulesSummary(categories: [FocusCategory], appName: (String) -> String) -> String {
        guard let breakRules else { return "Uses Settings" }
        if let names = breakRules.blockedNames(categories: categories, appName: appName) {
            return BreakRules.list(names).text
        }
        return breakRules.displayReminder == nil ? "Nothing blocked" : "Reminder only"
    }
}

// MARK: - Saying how a start went

/// What the workspace card remembers while it is up.
@MainActor
final class WorkspaceCardState: ObservableObject {
    /// The one page or app was allowed from the card, and what it says then.
    @Published var allowed = false
    var doneText = "Allowed from the next start"
}

extension NidusModel {
    static let workspaceHUDID = "focus.workspace"
    /// How long after the card appears the block card for a page it names
    /// stays quiet: the card already says that page is blocked, and a second
    /// card would replace it a second after it appeared.
    static let workspaceQuietSeconds: TimeInterval = 4

    /// A session just opened its workspace. Saves the bookmarks that were
    /// made again, then says so once if something could not be opened or a
    /// page the session blocks was among them. A start that went cleanly
    /// says nothing.
    func workspaceDidOpen(_ report: WorkspaceReport, for plan: SessionPlan) {
        if let id = plan.setupID, !report.refreshed.isEmpty {
            updateSetup(id) { setup in
                for fresh in report.refreshed {
                    if let index = setup.resources.firstIndex(where: { $0.id == fresh.id }) { setup.resources[index] = fresh }
                }
            }
        }
        // Which app opened each document is read once, now; nothing is opened.
        let openedBy = controller.map {
            WorkspaceConflicts.openers(for: plan.resources, launcher: $0.launcher, finder: $0.appFinder)
        } ?? [:]
        let conflicts = plan.workspaceConflicts(categories: categories, openedBy: openedBy)
        guard !report.isClean || !conflicts.isEmpty else { return }
        presentWorkspaceHUD(report, conflicts: conflicts, for: plan)
    }

    func presentWorkspaceHUD(_ report: WorkspaceReport, conflicts: [WorkspaceConflict], for plan: SessionPlan) {
        guard let host else { return }
        let setup = plan.setupID.flatMap { id in setups.first { $0.id == id } }
        let title = Self.workspaceCardTitle(setupName: setup?.displayName, report: report, conflicts: conflicts)
        let lines = Self.workspaceCardLines(report: report, conflicts: conflicts)
        // A page it names is blocked within a second; its own card would
        // replace this one.
        let rule = WebsiteRule(mode: plan.mode == .block ? .block : .allow, domains: plan.websites,
                               exceptions: plan.websiteExceptions)
        cards.workspaceQuietKeys = Set(conflicts.map { $0.app?.bundleID ?? rule.snoozeKey(for: $0.address) })
        cards.workspaceQuietUntil = Date().addingTimeInterval(Self.workspaceQuietSeconds)

        let state = WorkspaceCardState()
        let openSetup: (() -> Void)? = setup.map { setup in
            { [weak self] in
                self?.openSetupPage(setup)
                self?.host?.hud.dismiss(id: Self.workspaceHUDID)
            }
        }
        // One page, and a setup to add it to: the explicit fix, on the card.
        var allow: (() -> Void)?
        if let setup, conflicts.count == 1, conflicts[0].hasFix {
            let conflict = conflicts[0]
            allow = { [weak self] in
                guard let self else { return }
                let settingsApps = self.launchApps
                self.updateSetup(setup.id) { $0.allow(conflict, settingsLaunchApps: settingsApps) }
                state.allowed = true
                state.doneText = conflict.fixDone
                self.host?.hud.refresh(id: Self.workspaceHUDID, duration: 6,
                                       announcing: conflict.fixDone + ".")
                // The card gains a line saying so.
                self.host?.hud.remeasure(id: Self.workspaceHUDID)
            }
        }
        let request = HUDRequest(
            id: Self.workspaceHUDID,
            duration: 14,
            accessibilityLabel: ([title] + lines).joined(separator: " ")
        ) {
            WorkspaceNoticeCard(symbol: report.isClean ? "nosign" : "folder.badge.questionmark",
                                title: title, lines: lines, state: state,
                                openSetup: openSetup, allow: allow, allowTitle: conflicts.first?.cardFixTitle ?? "")
        }
        if host.hud.present(request) { host.feedback.play(.tick) }
    }

    /// "Grant writing: opened 2 of 3", or, when everything opened,
    /// "Grant writing: 1 page is blocked".
    nonisolated static func workspaceCardTitle(setupName: String?, report: WorkspaceReport, conflicts: [WorkspaceConflict]) -> String {
        let name = setupName.map { "\($0): " } ?? ""
        if !report.isClean {
            return setupName == nil ? "Opened \(report.opened) of \(report.total)"
                                    : name + "opened \(report.opened) of \(report.total)"
        }
        let n = conflicts.count
        let apps = conflicts.compactMap(\.app)
        if apps.count == n {
            // Documents that open in an app the session blocks.
            return name + (n == 1 ? "\(apps[0].name) is blocked" : "\(n) apps are blocked")
        }
        if apps.isEmpty { return name + (n == 1 ? "1 page is blocked" : "\(n) pages are blocked") }
        return name + "\(n) things are blocked"
    }

    /// The lines under the title: what could not be opened, then what is
    /// blocked. At most two sentences each, so the card stays short.
    nonisolated static func workspaceCardLines(report: WorkspaceReport, conflicts: [WorkspaceConflict]) -> [String] {
        var lines: [String] = []
        if !report.isClean { lines.append(report.detail) }
        switch conflicts.count {
        case 0: break
        case 1:
            lines.append(conflicts[0].cardSentence)
        default:
            // The title counts them and the setup's page names them.
            lines.append("This setup\u{2019}s own rules block them. Open the setup to allow the ones you want.")
        }
        return lines
    }
}

extension FocusCardState {
    /// Block-card keys that stay quiet until `workspaceQuietUntil`: the pages
    /// the workspace card has just named.
    func suppressesBlockedCard(for key: String, now: Date = Date()) -> Bool {
        workspaceQuietKeys.contains(key) && now < workspaceQuietUntil
    }
}

// MARK: - The card

/// The card for a workspace that did not all open, or opened a page its own
/// rules block: the setup's name, what happened, and what to do about it.
struct WorkspaceNoticeCard: View {
    let symbol: String
    let title: String
    let lines: [String]
    @ObservedObject var state: WorkspaceCardState
    let openSetup: (() -> Void)?
    let allow: (() -> Void)?
    var allowTitle = "Allow only this page"

    var body: some View {
        HStack(alignment: .top, spacing: NidusSpacing.md) {
            SettingsTile(symbol: symbol, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AdaptiveColors.surfacePrimaryText)
                ForEach(lines, id: \.self) { line in
                    Text(verbatim: line)
                        .font(.system(size: 12))
                        .foregroundStyle(AdaptiveColors.surfaceSecondaryText)
                        .lineLimit(5)
                }
                if state.allowed {
                    Label(state.doneText, systemImage: "checkmark")
                        .font(.system(size: 12))
                        .foregroundStyle(AdaptiveColors.surfaceSecondaryText)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: NidusSpacing.xsm) {
                if let allow, !state.allowed {
                    Button(allowTitle, action: allow)
                }
                if let openSetup {
                    Button("Open setup", action: openSetup)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
        }
        // The card's own width, so the text wraps to it: a card is sized
        // once, from what its content would like, and unwrapped text would
        // ask for one long line and a short card.
        .frame(width: HUDPresenter.width - (HUDPresenter.inset + 4) * 2)
        .accessibilityElement(children: .contain)
    }
}
