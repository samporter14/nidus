//
//  FocusSurfaces.swift
//  Nidus
//
//  The cards at the top of the screen (something was blocked, a snooze is
//  waiting out its pause, a session ended, a break is ending). The menu bar
//  item is FocusMenuBar; nidus:// links are NidusLinkRouting; the pause's
//  logic is SnoozeWait.
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
    static let snoozeWaitHUDID = "focus.snooze-wait"

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
        // Its pause is on screen already, counting down. Hearing it was
        // blocked again would replace the card and lose the count. (Only
        // while that card is the one showing: if another has taken its
        // place, this is news, and the link brings the count back.)
        if let wait = cards.snoozeWait, wait.key == key, host.hud.isShowing(id: Self.snoozeWaitHUDID) { return }
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
                snooze: { self?.requestSnooze(key) }
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
    /// `askAbout` is the goal to ask "did you finish?" about, if any. The
    /// card then asks first and offers Again only once it is answered: see
    /// `answerFinished`, which turns the question into its confirmation.
    func presentWrapUpHUD(for final: SessionState, completed: Bool, streak: Int? = nil, askAbout goal: String? = nil) {
        guard let host else { return }
        let cards = self.cards
        cards.finishAnswer = nil
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
            // The card reads the answer from `cards`, so it changes in place
            // whether the card's buttons or the menu bar gave it.
            FocusFinishReply(cards: cards) { reply in
                FocusWrapUpCard(
                    title: title,
                    detail: detail,
                    mediumDetail: mediumDetail,
                    shortDetail: shortDetail,
                    completed: completed,
                    button: breakMinutes == nil ? "Again" : "Skip break",
                    shortButton: breakMinutes == nil ? "Again" : "Skip",
                    question: goal,
                    reply: reply,
                    answer: { self?.answerFinished($0) },
                    again: {
                        if self?.isOnBreak == true { self?.skipBreak() } else { self?.startAgain() }
                        self?.host?.hud.dismiss(id: Self.completedHUDID)
                    }
                )
            }
        }
        if host.hud.present(request) {
            host.feedback.play(completed ? .success : .tick)
        }
    }
}

/// The wrap-up card: the result on the left, Again on the right. With a goal
/// to ask about it is two rows instead: the result over the question, and
/// once the question is answered its row turns into the confirmation and
/// Again. Both versions of that row are as tall, so the card does not move
/// (the card is measured once, when it comes up). On the narrower island card
/// it drops to the short form.
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
    /// The answer to it, once given.
    var reply: Bool? = nil
    var answer: (Bool) -> Void = { _ in }
    let again: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            // With a question, Again waits for the answer, on the second row.
            ViewThatFits(in: .horizontal) {
                row(detail, button: question == nil ? button : nil, last: false)
                row(mediumDetail, button: question == nil ? button : nil, last: false)
                row(shortDetail, button: question == nil ? shortButton : nil, last: true)
            }
            if let question {
                Group {
                    if let reply {
                        repliedRow(reply)
                    } else {
                        ViewThatFits(in: .horizontal) {
                            questionRow("Did you finish \u{201C}\(question)\u{201D}?", last: false)
                            questionRow("Did you finish?", last: false)
                            questionRow("Finished?", last: true)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: reply)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The last row truncates rather than running past the card's edge.
    private func row(_ detail: String, button: String?, last: Bool) -> some View {
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
            if let button { againButton(button) }
        }
    }

    private func againButton(_ title: String) -> some View {
        Button(title, action: again)
            .buttonStyle(.bordered)
            .fixedSize()
            .accessibilityLabel(title == "Again" ? "Start the same session again" : "Skip the break and start the next session")
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

    /// The same row once answered: a word or two, and Again (or Skip break).
    fileprivate func repliedRow(_ finished: Bool) -> some View {
        HStack(spacing: DroppySpacing.sm) {
            Text(verbatim: FinishReply.confirmation(finished))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .lineLimit(1)
            Spacer(minLength: DroppySpacing.sm)
            againButton(button)
        }
    }
}

/// What the card says back to "did you finish?", and for how long.
enum FinishReply {
    static func confirmation(_ finished: Bool) -> String {
        finished ? "Marked as finished." : "Saved for next time."
    }

    /// How long the card stays after an answer, to be read: as long as a
    /// card with nothing to ask.
    static let linger: TimeInterval = 6
}

/// Hands the card the reply to its question. The reply is kept in `cards`,
/// not in the card, because it can come from the menu bar too.
struct FocusFinishReply<Content: View>: View {
    let cards: FocusCardState
    @ViewBuilder let content: (Bool?) -> Content

    var body: some View {
        content(cards.finishAnswer)
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

// MARK: - A pause before a snooze

/// What the cards remember between one moment and the next. Held by the
/// model (the cards come and go), and observed, so a card on screen follows
/// it.
@MainActor @Observable
final class FocusCardState {
    /// The snooze whose card is counting down, if any.
    var snoozeWait: SnoozeWait?
    /// The answer to "did you finish?" for the wrap-up card now up: set by
    /// the card's buttons or the menu bar's items, cleared by the next card.
    var finishAnswer: Bool?
}

extension NidusModel.Key {
    /// Seconds to wait before a snooze; 0 snoozes right away.
    static let snoozeWait = "snoozeWaitSeconds"
}

extension NidusModel {
    /// Seconds Snooze waits before it lets anything through. Off (0) by
    /// default, which is how Snooze has always worked; a strict session has
    /// no snooze at all, wait or not.
    var snoozeWaitSeconds: Int {
        get { SnoozeWait.normalized(preference(Key.snoozeWait, default: 0)) }
        set { setPreference(SnoozeWait.normalized(newValue), Key.snoozeWait) }
    }

    /// Someone pressed Snooze on a card or the block page. With a wait set it
    /// opens the countdown card instead of snoozing; without one it snoozes
    /// as it always did. `snooze(_:)` stays the snooze itself, with nothing
    /// in front of it.
    func requestSnooze(_ key: String) {
        let name = engine?.session?.names[key] ?? key
        switch SnoozeWait.decide(key: key, name: name, waitSeconds: snoozeWaitSeconds,
                                 session: engine?.session, existing: cards.snoozeWait, now: Date()) {
        case .snoozeNow:
            snooze(key)
        case .refuse:
            // Strict, paused, or already let through: the card said Snooze
            // and there is nothing to do, so it goes.
            host?.hud.dismiss(id: Self.blockedHUDID)
        case .wait(let wait):
            cards.snoozeWait = wait
            presentSnoozeWaitHUD(wait)
        }
    }

    /// Snooze, pressed once the wait is over. Checked again here: the session
    /// may have moved on while the card was up.
    func confirmSnooze(_ wait: SnoozeWait) {
        guard cards.snoozeWait == wait else { return }
        guard wait.isReady(at: Date()), wait.isStillBlocked(in: engine?.session) else {
            return dropSnoozeWaitIfMoot()
        }
        cards.snoozeWait = nil
        snooze(wait.key)
        host?.hud.dismiss(id: Self.snoozeWaitHUDID)
    }

    /// Never mind: back to work, with nothing snoozed.
    func cancelSnoozeWait() {
        cards.snoozeWait = nil
        host?.hud.dismiss(id: Self.snoozeWaitHUDID)
    }

    /// Takes the card away once there is nothing left to wait for: the
    /// session ended or was paused, or the item was let through some other
    /// way. Called on every session event.
    func dropSnoozeWaitIfMoot() {
        guard let wait = cards.snoozeWait, !wait.isStillBlocked(in: engine?.session) else { return }
        cards.snoozeWait = nil
        host?.hud.dismiss(id: Self.snoozeWaitHUDID)
    }

    /// The countdown card. It runs its own once-a-second clock from the
    /// moment the wait began; `frozen` draws it at one moment instead, for
    /// the renders.
    func presentSnoozeWaitHUD(_ wait: SnoozeWait, asOf frozen: Date? = nil) {
        guard let host else { return }
        let request = DropletHUDRequest(
            id: Self.snoozeWaitHUDID,
            duration: wait.cardDuration,
            priority: .normal,
            accessibilityLabel: wait.spokenSummary,
            isExpanded: true,
            expandedContentHeight: 96
        ) {
            FocusHUDStrip(symbol: "hourglass", text: wait.name)
        } expanded: { [weak self] in
            FocusSnoozeWaitCard(wait: wait, asOf: frozen,
                                snooze: { self?.confirmSnooze(wait) },
                                cancel: { self?.cancelSnoozeWait() })
        }
        if host.hud.present(request) {
            host.feedback.play(.tick)
        }
    }

    /// Cards that need no more than the model to show (`--demo`,
    /// `--render-surfaces`). The wait card's moments are fixed ones, so the
    /// pictures do not depend on how long the render took.
    func runCardScenario(_ scenario: String) {
        let began = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let wait = SnoozeWait(key: "youtube.com", name: "youtube.com", startedAt: began, seconds: 10)
        switch scenario {
        case "snooze-wait-start": presentSnoozeWaitHUD(wait, asOf: began)
        case "snooze-wait-mid": presentSnoozeWaitHUD(wait, asOf: began.addingTimeInterval(5))
        case "snooze-wait-ready": presentSnoozeWaitHUD(wait, asOf: began.addingTimeInterval(10))
        case "snooze-link":
            // The block page's link, as the app receives it, with a 30 second wait.
            snoozeWaitSeconds = 30
            handle(URL(string: "nidus://snooze?site=youtube.com")!)
            snoozeWaitSeconds = 0
        default: break
        }
    }
}

/// The wait card: what is being snoozed, a countdown, and Never mind or
/// Snooze, which stays dim until the wait is over. Two rows, because the
/// sentence and both buttons do not fit on one.
struct FocusSnoozeWaitCard: View {
    let wait: SnoozeWait
    /// Draw the card at this moment, and keep it there.
    var asOf: Date? = nil
    let snooze: () -> Void
    let cancel: () -> Void

    var body: some View {
        Group {
            if let asOf {
                content(at: asOf)
            } else {
                // Ticks on the second the wait began, so the count changes
                // on the second and the button wakes on the dot.
                TimelineView(.periodic(from: wait.startedAt, by: 1)) { context in
                    content(at: context.date)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func content(at now: Date) -> some View {
        let left = wait.secondsLeft(at: now)
        return VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(alignment: .center, spacing: DroppySpacing.md) {
                FocusCountdownRing(secondsLeft: left, progress: wait.progress(at: now))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: wait.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    Text(verbatim: wait.detail(at: now))
                        .font(.system(size: 12))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            HStack(spacing: DroppySpacing.sm) {
                Spacer(minLength: 0)
                Button("Never mind", action: cancel)
                    .buttonStyle(.bordered)
                    .fixedSize()
                Button("Snooze", action: snooze)
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .disabled(left > 0)
                    .accessibilityLabel(wait.buttonLabel(at: now))
            }
        }
    }
}

/// The count in a ring that fills as the wait goes. When it is over the ring
/// fills in, clay with a white check, like the mark on the other cards. It
/// steps each second rather than sweeping: calmer, and nothing to switch off
/// for Reduce Motion.
struct FocusCountdownRing: View {
    let secondsLeft: Int
    /// 0 to 1.
    let progress: Double

    var body: some View {
        ZStack {
            if secondsLeft > 0 {
                Circle()
                    .stroke(Color.primary.opacity(0.14), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(FocusPalette.clay, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(secondsLeft)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            } else {
                Circle()
                    .fill(FocusPalette.clay.gradient)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 28, height: 28)
        // The sentence beside it says the same in words.
        .accessibilityHidden(true)
    }
}
