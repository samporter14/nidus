//
//  FocusSurfaces.swift
//  Nidus
//
//  The cards at the top of the screen (something was blocked, a session
//  ended, a break is ending). The menu bar item is FocusMenuBar; nidus://
//  links are NidusLinkRouting.
//

import Combine
import SwiftUI

// MARK: - HUD

extension NidusModel {
    static let blockedHUDID = "focus.blocked"
    static let completedHUDID = "focus.completed"
    static let welcomeHUDID = "focus.welcome"
    static let browserHUDID = "focus.browser"
    static let snoozeHUDID = "focus.snooze-ending"
    static let breakHUDID = "focus.break-ending"
    static let strictHUDID = "focus.strict"

    /// The break is about to end and the next session start. Stop here ends
    /// the run of sessions instead.
    func presentBreakEndingHUD(at end: Date, next plan: SessionPlan) {
        guard let host, isOnBreak else { return }
        let when = Text(end, style: .relative)
        let next = plan.goal.isEmpty ? "Next session starts" : "Next: \(plan.goal)"
        let seconds = max(1, Int(end.timeIntervalSinceNow.rounded()))
        let request = DropletHUDRequest(
            id: Self.breakHUDID,
            duration: min(10, max(3, Double(seconds) - 2)),
            priority: .normal,
            accessibilityLabel: "Break ends in \(seconds) seconds. \(next).",
            isExpanded: true,
            expandedContentHeight: 64
        ) {
            FocusHUDStrip(symbol: "cup.and.saucer.fill", text: "Break")
        } expanded: { [weak self] in
            FocusNoticeCard(symbol: "cup.and.saucer.fill", variants: [
                .init(title: Text("Break ends in \(when)"), detail: Text(verbatim: next), button: "Stop here"),
                .init(title: Text("Break ends"), detail: Text("in \(when)"), button: "Stop", showsSymbol: false),
            ]) {
                self?.endBreak()
            }
        }
        if host.hud.present(request) {
            host.feedback.play(.tick)
        }
    }

    /// Quitting cannot end a strict session; say why, briefly.
    func presentStrictHUD() {
        guard let host else { return }
        let request = DropletHUDRequest(id: Self.strictHUDID, duration: 4, priority: .normal,
                                        accessibilityLabel: "Strict session. End it early from the menu bar.") {
            FocusHUDStrip(symbol: "lock.fill", text: "Strict")
        } expanded: {
            FocusNoticeCard(symbol: "lock.fill", variants: [
                .init(title: Text("Strict session"),
                      detail: Text("End it early from the menu bar."), button: "OK"),
            ]) {
                host.hud.dismiss(id: Self.strictHUDID)
            }
        }
        host.hud.present(request)
    }

    /// A browser refused Focus mid-session, so its tabs are not being
    /// redirected. Said once per browser per session, with the one action
    /// that fixes it: ask (the prompt comes from macOS), or open the
    /// Automation pane when the answer was no.
    func presentBrowserAccessHUD(for browser: BrowserProfile, needsConsent: Bool) {
        guard let host else { return }
        let name = browser.shortName
        let title = "Can't block sites in \(name)"
        let detail = needsConsent ? "Nidus needs your permission to control it." : "Nidus isn't allowed to control it."
        let short = needsConsent ? "Needs your permission" : "Not allowed"
        let button = needsConsent ? "Allow…" : "Fix…"
        let request = DropletHUDRequest(
            id: Self.browserHUDID,
            duration: 12,
            priority: .normal,
            accessibilityLabel: "\(title). \(detail)",
            isExpanded: true,
            expandedContentHeight: 64
        ) {
            FocusHUDStrip(symbol: "exclamationmark.triangle.fill", text: name)
        } expanded: { [weak self] in
            FocusNoticeCard(symbol: "exclamationmark.triangle.fill", variants: [
                .init(title: Text(verbatim: title), detail: Text(verbatim: detail), button: button),
                .init(title: Text(verbatim: title), detail: Text(verbatim: short), button: button),
                // The island leaves about 115pt beside the button: the gist.
                .init(title: Text(verbatim: name),
                      detail: Text(verbatim: needsConsent ? "Needs access" : "Access is off"),
                      button: needsConsent ? "Allow" : "Fix", showsSymbol: false),
            ]) {
                if needsConsent { self?.askBrowserAccess(browser) } else { self?.openAutomationSettings() }
                self?.host?.hud.dismiss(id: Self.browserHUDID)
            }
        }
        if host.hud.present(request) {
            host.feedback.play(.failure)
        }
    }

    /// A snooze is about to run out, so what it let through does not vanish
    /// without warning. Block now ends it early.
    func presentSnoozeEndingHUD(for item: String, at end: Date) {
        guard let host, isActive else { return }
        let name = engine?.session?.names[item] ?? item
        let seconds = max(1, Int(end.timeIntervalSinceNow.rounded()))
        let when = Text(end, style: .relative)
        let request = DropletHUDRequest(
            id: Self.snoozeHUDID,
            duration: min(8, max(3, Double(seconds) - 2)),
            priority: .normal,
            accessibilityLabel: "Snooze ends in \(seconds) seconds. \(name) is blocked again after that.",
            isExpanded: true,
            expandedContentHeight: 64
        ) {
            FocusHUDStrip(symbol: "hourglass", text: name)
        } expanded: { [weak self] in
            FocusNoticeCard(symbol: "hourglass", variants: [
                .init(title: Text("Snooze ends in \(when)"), detail: Text(verbatim: "\(name) is blocked again after that."), button: "Block now"),
                .init(title: Text("Snooze ends in \(when)"), detail: Text(verbatim: name), button: "Block now"),
                .init(title: Text(verbatim: "Snooze ends"), detail: Text("in \(when) · \(name)"), button: "Block now", showsSymbol: false),
            ]) {
                self?.controller?.endSnooze(item)
                self?.host?.hud.dismiss(id: Self.snoozeHUDID)
            }
        }
        if host.hud.present(request) {
            host.feedback.play(.tick)
        }
    }

    /// Once, on a first install: where Nidus lives, and a way to the guide
    /// at the top of its settings.
    func presentWelcomeHUD() {
        guard let host else { return }
        let request = DropletHUDRequest(
            id: Self.welcomeHUDID,
            duration: 12,
            priority: .normal,
            accessibilityLabel: "Nidus is ready. Start a session from the menu bar.",
            isExpanded: true,
            expandedContentHeight: 64
        ) {
            FocusHUDStrip(icon: FocusWelcomeCard.glyph, text: "Nidus")
        } expanded: { [weak self] in
            FocusWelcomeCard(showMe: {
                self?.openSettings()
                self?.host?.hud.dismiss(id: Self.welcomeHUDID)
            })
        }
        host.hud.present(request)
    }

    /// The moment something is stopped: a card naming it, the session's goal
    /// and time left, and a Snooze that lets it through for a few minutes.
    func presentBlockedHUD(for item: BlockedItem) {
        guard let host else { return }
        let name = item.displayName
        let key = item.snoozeKey
        let time = isOpenEnded ? "Open-ended" : FocusFormat.short(remaining)
        let detail = goal.isEmpty ? time : "\(goal) · \(time)"
        let spokenTime = isOpenEnded ? "open-ended session" : FocusFormat.spoken(remaining)
        let snoozeTitle: String? = isStrict ? nil : "Snooze \(snoozeMinutes) min"
        let verb: String
        switch item {
        case .app(_, _, let quit): verb = quit ? "quit" : "hidden"
        case .website: verb = "blocked"
        }

        let request = DropletHUDRequest(
            id: Self.blockedHUDID,
            duration: 5,
            priority: .normal,
            accessibilityLabel: "\(name) \(verb). \(goal.isEmpty ? "" : goal + ", ")\(spokenTime).",
            isExpanded: true,
            expandedContentHeight: 64
        ) {
            FocusHUDStrip(symbol: "nosign", text: name)
        } expanded: { [weak self] in
            FocusBlockedCard(
                title: "\(name) \(verb)",
                detail: detail,
                shortDetail: time,
                snoozeTitle: snoozeTitle,
                snooze: { self?.snooze(key) }
            )
        }
        if host.hud.present(request) {
            host.feedback.play(.tick)
        }
    }

    /// The end of a session: how long was focused and how often something
    /// was blocked, with Again to go straight into another.
    /// `streak` is set on the day's first session when it carries a streak
    /// of two days or more: "day 12 in a row".
    /// `askAbout` is the goal to ask "did you finish?" about, if any.
    func presentWrapUpHUD(for final: SessionState, completed: Bool, streak: Int? = nil, askAbout goal: String? = nil) {
        guard let host else { return }
        let focused = final.focusedTime ?? 0
        let minutes = Int((focused / 60).rounded())
        let time = minutes < 1 ? "Under a minute" : FocusFormat.duration(minutes: minutes)
        let blocked = final.blocks.values.reduce(0, +)
        let blocks = blocked == 0 ? "nothing needed blocking" : "blocked \(blocked) \(blocked == 1 ? "time" : "times")"
        let title = completed ? "Session complete" : "Session ended"
        let days = streak.map { "day \($0) in a row" }
        // A break follows a completed session when breaks are on.
        let breakMinutes = engine?.breakState.map { Int(($0.length / 60).rounded()) }
        let rest = breakMinutes.map { "\($0) min break" }
        let detail = [ "\(time) focused", blocks, days, rest ].compactMap { $0 }.joined(separator: " · ")
        let mediumDetail = [ "\(time) focused", days ?? (rest == nil ? blocks : nil), rest ].compactMap { $0 }.joined(separator: " · ")
        let shortDetail = rest.map { "\(time) · \($0)" } ?? streak.map { "\(time) · day \($0)" }
            ?? (blocked == 0 ? "\(time) focused" : "\(time) · \(blocked) blocked")
        let request = DropletHUDRequest(
            id: Self.completedHUDID,
            // Long enough to answer the question, when there is one.
            duration: goal == nil ? 6 : 12,
            priority: .normal,
            accessibilityLabel: "\(title). \(time) focused, \(blocks)\(days.map { ", \($0)" } ?? "")\(rest.map { ". A \($0) now" } ?? "")."
                + (goal.map { " Did you finish \($0)?" } ?? ""),
            isExpanded: true,
            expandedContentHeight: goal == nil ? 64 : 96
        ) {
            FocusHUDStrip(symbol: completed ? "checkmark.circle.fill" : "stop.circle", text: time)
        } expanded: { [weak self] in
            FocusWrapUpCard(
                title: title,
                detail: detail,
                mediumDetail: mediumDetail,
                shortDetail: shortDetail,
                completed: completed,
                button: breakMinutes == nil ? "Again" : "Skip break",
                shortButton: breakMinutes == nil ? "Again" : "Skip",
                question: goal,
                answer: { self?.answerFinished($0) },
                again: {
                    if self?.isOnBreak == true { self?.skipBreak() } else { self?.startAgain() }
                    self?.host?.hud.dismiss(id: Self.completedHUDID)
                }
            )
        }
        if host.hud.present(request) {
            host.feedback.play(completed ? .success : .tick)
        }
    }
}

/// The wrap-up card: the result on the left, Again on the right. On the
/// narrower island card it drops to the short form.
struct FocusWrapUpCard: View {
    let title: String
    let detail: String
    let mediumDetail: String
    let shortDetail: String
    let completed: Bool
    var button = "Again"
    /// The island's card has room for a shorter word.
    var shortButton = "Again"
    /// The goal to ask "did you finish?" about, on a second row.
    var question: String? = nil
    var answer: (Bool) -> Void = { _ in }
    let again: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            ViewThatFits(in: .horizontal) {
                row(detail, button: button, last: false)
                row(mediumDetail, button: button, last: false)
                row(shortDetail, button: shortButton, last: true)
            }
            if let question {
                ViewThatFits(in: .horizontal) {
                    questionRow("Did you finish \u{201C}\(question)\u{201D}?", last: false)
                    questionRow("Did you finish?", last: false)
                    questionRow("Finished?", last: true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The last row truncates rather than running past the card's edge.
    private func row(_ detail: String, button: String, last: Bool) -> some View {
        HStack(alignment: .center, spacing: DroppySpacing.md) {
            // The island has no room for the mark; the title says it.
            if !last {
                SettingsTile(symbol: completed ? "checkmark" : "stop.fill", size: 28, color: completed ? FocusPalette.clay : .gray)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Text(verbatim: detail)
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: !last, vertical: false)
            Spacer(minLength: DroppySpacing.sm)
            Button(button, action: again)
                .buttonStyle(.bordered)
                .fixedSize()
                .accessibilityLabel(button == "Again" ? "Start the same session again" : "Skip the break and start the next session")
        }
    }
}

extension FocusWrapUpCard {
    /// The question under the result: Not yet, and a clay Yes.
    fileprivate func questionRow(_ text: String, last: Bool) -> some View {
        HStack(spacing: DroppySpacing.sm) {
            Text(verbatim: text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .fixedSize(horizontal: !last, vertical: false)
            Spacer(minLength: DroppySpacing.sm)
            Button("Not yet") { answer(false) }
                .buttonStyle(.bordered)
                .fixedSize()
                .accessibilityLabel("Not finished yet")
            Button("Yes") { answer(true) }
                .buttonStyle(.borderedProminent)
                .tint(FocusPalette.clay)
                .fixedSize()
                .accessibilityLabel("Yes, finished")
        }
    }
}

/// The first-run card: Focus's own glyph, where to start, and Show me,
/// which opens the Get started guide in Settings.
struct FocusWelcomeCard: View {
    let showMe: () -> Void

    /// The menu bar's resting glyph, so the card shows what to look for.
    static var glyph: Image {
        Image(nsImage: FocusGlyph.image(.particle, pointSize: 20)).renderingMode(.template)
    }

    /// The same glyph at text size, sitting on the baseline like a letter.
    static var inlineGlyph: Text {
        Text(Image(nsImage: FocusGlyph.image(.particle, pointSize: 13)).renderingMode(.template))
            .baselineOffset(-2.5)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row("Start a session from the menu bar.", glyph: true)
            row("Start from the menu bar.", glyph: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func row(_ detail: String, glyph: Bool) -> some View {
        HStack(alignment: .center, spacing: DroppySpacing.md) {
            if glyph {
                SettingsTile(image: Self.glyph, size: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Nidus is ready")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Text(verbatim: detail)
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
            .lineLimit(1)
            .fixedSize()
            Spacer(minLength: DroppySpacing.sm)
            Button("Show me", action: showMe)
                .buttonStyle(.bordered)
                .fixedSize()
                .accessibilityLabel("Show how to use Nidus, in Settings")
        }
    }
}

/// A card with one action: a symbol, a title over a line, and a
/// button. Variants go longest first; the first that fits is shown, so the
/// island's narrower card gets a shorter one.
struct FocusNoticeCard: View {
    struct Variant {
        var title: Text
        var detail: Text
        var button: String
        var showsSymbol = true
    }

    let symbol: String
    let variants: [Variant]
    let action: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(variants[0], last: variants.count == 1)
            if variants.count > 1 { row(variants[1], last: variants.count == 2) }
            if variants.count > 2 { row(variants[2], last: true) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The last variant is what shows when nothing fits, so its text gives
    /// way (truncating) rather than running past the card's edge.
    private func row(_ v: Variant, last: Bool) -> some View {
        HStack(alignment: .center, spacing: DroppySpacing.md) {
            if v.showsSymbol {
                SettingsTile(symbol: symbol, size: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                v.title
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                v.detail
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: !last, vertical: false)
            Spacer(minLength: DroppySpacing.sm)
            Button(v.button, action: action)
                .buttonStyle(.bordered)
                .fixedSize()
        }
    }
}

/// Glyph at the far left, text at the far right, nothing in the middle: on a
/// notch the middle of a strip is the camera housing.
struct FocusHUDStrip: View {
    let icon: Image
    let text: String

    init(symbol: String, text: String) {
        self.init(icon: Image(systemName: symbol), text: text)
    }

    init(icon: Image, text: String) {
        self.icon = icon
        self.text = text
    }

    var body: some View {
        HStack(spacing: 0) {
            icon
                .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .semibold))
            Spacer(minLength: 0)
            Text(verbatim: text)
                .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 80, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
    }
}

/// The card: what was stopped, the goal and time left, and Snooze. The
/// island's card is 208pt wide against 344 on a notch, so when the full row
/// does not fit it drops the goal and shortens the button.
struct FocusBlockedCard: View {
    let title: String
    let detail: String
    let shortDetail: String
    /// nil in a strict session, which has no snooze.
    let snoozeTitle: String?
    let snooze: () -> Void

    var body: some View {
        // The goal gives way first, truncating; the name and Snooze stay.
        row(detail: detail, button: snoozeTitle, last: false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The short row truncates a long name rather than overflowing.
    private func row(detail: String, button: String?, last: Bool) -> some View {
        HStack(alignment: .center, spacing: DroppySpacing.md) {
            if !last { SettingsTile(symbol: "nosign", size: 28) }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Text(verbatim: detail)
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: DroppySpacing.sm)
            if let button {
                Button(button, action: snooze)
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .accessibilityLabel(snoozeTitle ?? button)
            }
        }
    }
}
