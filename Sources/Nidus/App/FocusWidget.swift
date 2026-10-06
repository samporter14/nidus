//
//  FocusWidget.swift
//  Nidus
//
//  The popover's content: where a session is set up and started, and where
//  it is paused, extended or ended. (It was the droplet's shelf widget.)
//

import SwiftUI

/// Where the widget is shown. In the app it is always the popover, at full
/// width; the droplet also had a narrow, paired form.
struct ShelfWidgetContext {
    var isCompact = false
    var contentInsets = EdgeInsets()
}

/// The popover: a header row, then the goal and Start, or the running
/// session's clock and controls.
struct FocusWidget: View {
    @ObservedObject var model: NidusModel
    let context: ShelfWidgetContext
    /// Where ↑ and ↓ are in the recent goals; nil is the field as typed.
    @State private var recentIndex: Int?
    /// A strict session's End asks for this phrase first.
    @State private var confirmingEnd = false
    @State private var endPhrase = ""
    @FocusState private var goalFocused: Bool
    @FocusState private var phraseFocused: Bool
    @FocusState private var customLengthFocused: Bool
    @State private var todayCache = TodayLineCache()
    static let strictEndPhrase = "stop early"

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            header
            if model.isActive {
                if context.isCompact { compactRunning } else { running }
            } else if model.isOnBreak {
                if context.isCompact { compactBreak } else { breakView }
            } else {
                if context.isCompact { compactIdle } else { idle }
            }
            // No trailing Spacer: the root frame already aligns to the top,
            // and the stack's spacing before a Spacer would add 8pt the
            // declared height does not have.
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DroppySpacing.sm) {
            Image(nsImage: FocusGlyph.image(model.isActive ? .brain : .particle, pointSize: 15))
                .renderingMode(.template)
                .foregroundStyle(model.isActive && !model.isPaused ? AnyShapeStyle(FocusPalette.clay) : AnyShapeStyle(.tertiary))
                .accessibilityHidden(true)
            Text(stateWord)
                .font(.headline)
            if model.isStrict || (model.strictMode && !model.isActive && !model.isOnBreak) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .help(model.isStrict ? "Strict session: no snooze or pause" : "Strict mode is on")
                    .accessibilityLabel(model.isStrict ? "Strict session" : "Strict mode on")
            }
            Spacer(minLength: 0)
            if !model.isActive, !model.isOnBreak {
                Button(action: model.openSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .help("Nidus settings")
                .accessibilityLabel("Nidus settings")
            }
        }
        .frame(height: 26)
    }

    /// The header's one word for where things stand.
    private var stateWord: String {
        if model.isOnBreak { return "Break" }
        if model.isActive {
            if model.isPaused { return "Paused" }
            return model.isOpenEnded ? "Focusing · open-ended" : "Focusing"
        }
        return "New session"
    }

    // MARK: Idle

    /// The goal, then the choices and Start, then a quiet line of today. It
    /// has no fixed height: whatever is added below the goal moves the rest
    /// down, and the popover follows its content.
    private var idle: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.md) {
            HStack(spacing: DroppySpacing.sm) {
                TextField("What are you working on?", text: $model.goalDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.extraLarge)
                    .focused($goalFocused)
                    .onSubmit(start)
                    .onKeyPress(.upArrow) { stepRecentGoal(1) }
                    .onKeyPress(.downArrow) { stepRecentGoal(-1) }
                    .accessibilityLabel("Goal")
                if !model.recentGoals.isEmpty {
                    recentGoalsMenu
                }
            }
            .onAppear {
                model.requestKeyboardFocus()
                // The calendar is read only when someone is about to start.
                model.refreshNextMeeting()
                DispatchQueue.main.async {
                    if model.customLengthDraft == nil { goalFocused = true } else { customLengthFocused = true }
                }
            }

            // Saved setups, one click each; draws nothing until there are any.
            FocusSetupsBar(model: model)

            VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                HStack(spacing: DroppySpacing.sm) {
                    if model.customLengthDraft == nil {
                        durationMenu
                    } else {
                        customLengthField
                    }
                    categoryMenu
                    Spacer(minLength: DroppySpacing.sm)
                    startButton
                }
                if let draft = model.customLengthDraft {
                    customLengthCaption(draft)
                }
            }
            // Return in the field, a choice from the Length menu or Escape
            // moves focus on: the field takes it when it opens, the goal
            // gets it back when it closes.
            .onChange(of: model.customLengthDraft != nil) { _, isOpen in
                if isOpen { focusCustomLengthField() } else { goalFocused = true }
            }

            if let line = todayCache.line(for: model) {
                Text(verbatim: line)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// Start, with any length still being typed taken first, as Return in
    /// the field would. If it cannot be read nothing starts: a session of a
    /// length nobody chose would block things for the wrong time.
    private func start() {
        guard model.commitCustomLength() else { return }
        model.startSession()
    }

    private var compactIdle: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            startButton
            Text(verbatim: "\(model.lengthLabel) · \(model.selectionSummary)")
                .font(.system(size: 11))
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                .lineLimit(1)
        }
    }

    /// The last few goals, to start one again without typing it.
    private var recentGoalsMenu: some View {
        Menu {
            Section("Recent goals") {
                ForEach(model.recentGoals, id: \.self) { goal in
                    Button(goal) {
                        model.goalDraft = goal
                        recentIndex = model.recentGoals.firstIndex(of: goal)
                    }
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.extraLarge)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Recent goals")
        .accessibilityLabel("Recent goals")
    }

    /// ↑ steps back through the recent goals and ↓ forward, back to an
    /// empty field, as a shell's history does.
    private func stepRecentGoal(_ step: Int) -> KeyPress.Result {
        let goals = model.recentGoals
        guard !goals.isEmpty else { return .ignored }
        let next = (recentIndex ?? -1) + step
        if next < 0 {
            recentIndex = nil
            model.goalDraft = ""
        } else if next < goals.count {
            recentIndex = next
            model.goalDraft = goals[next]
        }
        return .handled
    }

    private var startButton: some View {
        Button("Start", action: start)
            .buttonStyle(.borderedProminent)
            .tint(FocusPalette.clay)
            .controlSize(.large)
            // While a length is being typed Return belongs to the field.
            .keyboardShortcut(model.customLengthDraft == nil ? .defaultAction : nil)
            // Start and the Length button keep their size; a long category
            // name gives way (it ends in …) before either is squeezed.
            .fixedSize()
            .layoutPriority(1)
            .disabled(model.selectedCategories.allSatisfy(\.isEmpty) && model.mode == .block)
            .help("Start a focus session")
    }

    private var durationMenu: some View {
        Menu {
            let until = model.pendingUntil()
            ForEach(NidusModel.durationChoices, id: \.self) { minutes in
                Toggle(FocusFormat.duration(minutes: minutes), isOn: Binding(
                    get: { until == nil && !model.endsAtNextMeeting && model.durationMinutes == minutes },
                    set: { if $0 { model.durationMinutes = minutes } }
                ))
            }
            // "Until 2:00 PM (Design review)", with its own divider, or
            // nothing without Calendar or a meeting left today.
            UntilNextMeetingMenuItem(model: model)
            Divider()
            if let until {
                // The one-off time, checked while it is the choice; choosing
                // it again lets go of it and the saved length is back.
                Toggle("Until \(FocusFormat.clockTime(until))", isOn: Binding(
                    get: { true },
                    set: { if !$0 { model.untilTarget = nil } }
                ))
            } else if !NidusModel.durationChoices.contains(model.durationMinutes) {
                // A saved length that is not one of the above: typed here
                // earlier, so listed and checked.
                Toggle(FocusFormat.duration(minutes: model.durationMinutes), isOn: .constant(!model.endsAtNextMeeting))
            }
            Button("Custom…", action: model.openCustomLength)
        } label: {
            menuLabel(model.lengthLabel, symbol: "timer")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .fixedSize()
        .layoutPriority(1)
        .accessibilityLabel("Length")
    }

    /// "Custom…" swaps the Length button for this: a length or an end time,
    /// typed. Return sets it, Escape or the cross puts the button back.
    private var customLengthField: some View {
        HStack(spacing: DroppySpacing.xs) {
            TextField("Length", text: customLengthText, prompt: Text("40, 1h30, until 3:30"))
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($customLengthFocused)
                .onSubmit { model.commitCustomLength() }
                .onKeyPress(.escape) {
                    model.cancelCustomLength()
                    return .handled
                }
                .onExitCommand { model.cancelCustomLength() }
                // Unreadable text is outlined, softly, not shaken or reddened.
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.7), lineWidth: 1)
                        .opacity(model.customLengthDraft?.rejected == nil ? 0 : 1)
                        .allowsHitTesting(false)
                }
                // The categories give way before the field does, and the
                // field before Start: the row must fit 400pt.
                .frame(minWidth: 96, maxWidth: 150)
                .accessibilityLabel("Custom length")
            Button(action: model.cancelCustomLength) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .help("Keep \(model.lengthLabel)")
            .accessibilityLabel("Cancel custom length")
        }
    }

    private var customLengthText: Binding<String> {
        Binding(
            get: { model.customLengthDraft?.text ?? "" },
            set: {
                // The field writes its text back as it gains focus and ends
                // editing; only a real edit lets go of the gentle error.
                guard model.customLengthDraft?.text != $0 else { return }
                model.customLengthDraft?.text = $0
                model.customLengthDraft?.rejected = nil
            }
        )
    }

    /// Under the field: how to write a length, what the text means, or why
    /// it was not taken.
    @ViewBuilder
    private func customLengthCaption(_ draft: CustomLengthDraft) -> some View {
        switch draft.caption() {
        case .hint(let text):
            Text(verbatim: text).foregroundStyle(.secondary)
        case .preview(let text):
            Text(verbatim: "\(text) · Return to set").foregroundStyle(.secondary)
        case .problem(let text):
            Label {
                Text(verbatim: text).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            }
            .labelStyle(.titleAndIcon)
        }
    }

    /// The menu that chose "Custom…" is still closing, and hands focus back
    /// to the goal field as it goes: ask now, and once more after it has.
    private func focusCustomLengthField() {
        DispatchQueue.main.async { customLengthFocused = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if model.customLengthDraft != nil { customLengthFocused = true }
        }
    }

    private var categoryMenu: some View {
        Menu {
            ForEach(model.categories) { category in
                Toggle(isOn: Binding(
                    get: { model.isSelected(category) },
                    set: { _ in model.toggleSelection(category) }
                )) {
                    Label(category.name, systemImage: category.symbol)
                }
            }
            Divider()
            Button("Edit categories…", action: model.openSettings)
        } label: {
            menuLabel(
                model.mode == .allow ? "Only \(model.selectionSummary)" : model.selectionSummary,
                symbol: model.mode == .allow ? "checkmark.shield" : "nosign"
            )
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(model.mode == .allow ? "Allowed categories" : "Blocked categories")
    }

    private func menuLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: DroppySpacing.xs) {
            Image(systemName: symbol)
            Text(verbatim: title).lineLimit(1)
        }
    }

    // MARK: Running

    /// The goal and a quiet line, the clock and the controls, and the
    /// progress bar. The bar ends 13pt above the bottom edge, clear of the
    /// clipped corners; the quiet line sits above the clock so the buttons
    /// stay level with the clock, and nothing sits in the bottom corners.
    private var running: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            if confirmingEnd, model.isStrict {
                strictEndRow
            } else {
                runningControls
            }
            if !model.isOpenEnded {
                progressBar
            }
        }
        .onChange(of: model.isActive) { _, active in
            if !active { cancelStrictEnd() }
        }
        .onAppear { if model.harnessOpensStrictEnd { confirmingEnd = true } }
    }

    private var runningControls: some View {
        HStack(alignment: .bottom, spacing: DroppySpacing.md) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: model.goal.isEmpty ? "Blocking \(model.runningSummary)" : model.goal)
                    .font(.system(size: model.goal.isEmpty ? 13 : 15, weight: model.goal.isEmpty ? .regular : .medium))
                    .foregroundStyle(model.goal.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // When it ends (or began), and how often something was
                // blocked. What is blocked is a tooltip: it never changes
                // during a session, and a goal-less one already says it above.
                Text(verbatim: model.runningLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(model.goal.isEmpty ? "" : "Blocking \(model.runningSummary)")
                    .accessibilityLabel(model.runningLine.replacingOccurrences(of: " · ", with: ", "))
                clock(size: 44)
            }
            Spacer(minLength: DroppySpacing.md)
            HStack(spacing: DroppySpacing.sm) {
                if !model.isStrict { pauseButton }
                if !model.isOpenEnded {
                    Button(action: model.addTime) {
                        Text("+5")
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
                    .help("Add 5 minutes")
                    .accessibilityLabel("Add 5 minutes")
                }
                Button {
                    if model.isStrict { confirmingEnd = true } else { model.endSession() }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
                .help(model.isStrict ? "End early" : "End session")
                .accessibilityLabel(model.isStrict ? "End early" : "End session")
            }
            .padding(.bottom, 8)
        }
    }

    /// A strict session ends early only after typing the phrase: enough to
    /// get past an impulse, not a lock.
    private var strictEndRow: some View {
        HStack(spacing: DroppySpacing.sm) {
            TextField("Type \u{201C}\(Self.strictEndPhrase)\u{201D} to end", text: $endPhrase)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($phraseFocused)
                .onAppear {
                    model.requestKeyboardFocus()
                    DispatchQueue.main.async { phraseFocused = true }
                }
                .onSubmit(confirmStrictEnd)
                .accessibilityLabel("Type \(Self.strictEndPhrase) to end the session early")
            Button("Keep going", action: cancelStrictEnd)
                .buttonStyle(.bordered)
                .fixedSize()
            Button("End", action: confirmStrictEnd)
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .disabled(!strictPhraseMatches)
        }
        .frame(height: 36)
    }

    private var strictPhraseMatches: Bool {
        endPhrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == Self.strictEndPhrase
    }

    private func confirmStrictEnd() {
        guard strictPhraseMatches else { return }
        cancelStrictEnd()
        model.endSession()
    }

    private func cancelStrictEnd() {
        confirmingEnd = false
        endPhrase = ""
    }

    // MARK: Break

    /// Between sessions: the break's time, quiet rather than clay, with
    /// Start now and End.
    private var breakView: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(alignment: .bottom, spacing: DroppySpacing.md) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: model.nextGoal.isEmpty ? "Next: another session" : "Next: \(model.nextGoal)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    breakClock(size: 44)
                }
                Spacer(minLength: DroppySpacing.md)
                HStack(spacing: DroppySpacing.sm) {
                    skipBreakButton(size: 30)
                    Button(action: model.endBreak) {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
                    .help("Stop here: no session follows")
                    .accessibilityLabel("End the break")
                }
                .padding(.bottom, 8)
            }
            ProgressTrack(progress: model.breakProgress, tint: .gray)
        }
    }

    private var compactBreak: some View {
        VStack(alignment: .leading, spacing: 2) {
            breakClock(size: 28)
            Text(verbatim: model.nextGoal.isEmpty ? "Break" : "Then \(model.nextGoal)")
                .font(.system(size: 11))
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                .lineLimit(1)
        }
    }

    private func breakClock(size: CGFloat) -> some View {
        Text(verbatim: model.clockText)
            .font(.system(size: size, weight: .light))
            .monospacedDigit()
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            .accessibilityLabel("Break, \(FocusFormat.spoken(model.breakRemaining))")
    }

    private func skipBreakButton(size: CGFloat) -> some View {
        Button(action: model.skipBreak) {
            Image(systemName: "play.fill")
        }
        .buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
        .help("Start the next session now")
        .accessibilityLabel("Start the next session now")
    }

    private var compactRunning: some View {
        VStack(alignment: .leading, spacing: 2) {
            clock(size: 28)
            Text(verbatim: model.goal.isEmpty ? model.runningSummary : model.goal)
                .font(.system(size: 11))
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                .lineLimit(1)
        }
    }

    private func clock(size: CGFloat) -> some View {
        Text(verbatim: model.clockText)
            .font(.system(size: size, weight: .light))
            .monospacedDigit()
            .foregroundStyle(model.isPaused ? AdaptiveColors.notchSurfaceTertiaryText : AdaptiveColors.notchSurfacePrimaryText)
            .accessibilityLabel(model.isOpenEnded
                ? "Focused for \(FocusFormat.spoken(model.elapsed).replacingOccurrences(of: " left", with: ""))"
                : FocusFormat.spoken(model.remaining))
    }

    private var pauseButton: some View {
        Button(action: model.togglePause) {
            Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                .id(model.isPaused)
                .transition(DroppyTransition.element)
        }
        .buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
        .help(model.isPaused ? "Resume" : "Pause")
        .accessibilityLabel(model.isPaused ? "Resume" : "Pause")
    }

    private var progressBar: some View {
        ProgressTrack(progress: model.progress, tint: model.isPaused ? .gray : FocusPalette.clay)
    }
}

/// The idle footer's text, worked out again only when the history, the day
/// or the setting changes. A full history is 5,000 sessions, and the popover
/// draws again on every key typed into the goal.
@MainActor
final class TodayLineCache {
    private struct Key: Equatable {
        var historyVersion: Int
        var day: Date
        var recording: Bool
    }
    private var key: Key?
    private var text: String?

    func line(for model: NidusModel, now: Date = Date()) -> String? {
        let current = Key(historyVersion: model.controller?.historyVersion ?? 0,
                          day: Calendar.current.startOfDay(for: now), recording: model.recordsHistory)
        if current != key {
            key = current
            text = model.todayLine
        }
        return text
    }
}

/// A session's progress: the system's bar, in clay.
struct ProgressTrack: View {
    let progress: Double
    let tint: Color

    var body: some View {
        ProgressView(value: min(1, max(0, progress)))
            .progressViewStyle(.linear)
            .tint(tint)
            .accessibilityHidden(true)
    }
}

extension NidusModel {
    /// How many times the running session has blocked something.
    var blockedCount: Int {
        engine?.session?.blocks.values.reduce(0, +) ?? 0
    }

    /// "Until 3:40 PM · blocked 2 times", the quiet line of a running session.
    var runningLine: String {
        guard let session = engine?.session else { return "" }
        var endsAt: Date?
        if session.plan.duration != nil, case .running(let deadline) = session.phase { endsAt = deadline }
        return FocusFormat.runningLine(paused: isPaused, blocking: engine?.enforcement != nil, endsAt: endsAt,
                                       startedAt: session.startedAt, blocked: blockedCount)
    }

    /// "Today 1 hr 10 min · 3-day streak" for the foot of the idle popover; nil
    /// when sessions are not being recorded, since a line about the history
    /// the user turned off would be a line about nothing, and when there is
    /// nothing to say (see `FocusFormat.todayLine`).
    var todayLine: String? {
        guard recordsHistory, let sessions = controller?.history.sessions, !sessions.isEmpty else { return nil }
        // One week is enough for today; the streak reads the whole history.
        let stats = FocusStats(sessions: sessions, weeks: 1)
        return FocusFormat.todayLine(focused: stats.focusedToday, streak: stats.currentStreak)
    }

    /// What the running session blocks, by category name when it can.
    var runningSummary: String {
        guard let plan = engine?.session?.plan else { return "" }
        let apps = plan.apps.count, sites = plan.websites.count
        let prefix = plan.mode == .allow ? "everything but " : ""
        var parts: [String] = []
        if apps > 0 { parts.append("\(apps) app\(apps == 1 ? "" : "s")") }
        if sites > 0 { parts.append("\(sites) website\(sites == 1 ? "" : "s")") }
        return prefix + (parts.isEmpty ? "nothing" : parts.joined(separator: " and "))
    }
}
