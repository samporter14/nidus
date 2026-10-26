//
//  FocusWidget.swift
//  Nidus
//
//  The popover's content: where a session is set up and started, and where
//  it is paused, extended or ended.
//

import SwiftUI

/// The popover: a header row, then the goal and Start, or the running
/// session's clock and controls.
struct FocusWidget: View {
    @ObservedObject var model: NidusModel
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
        VStack(alignment: .leading, spacing: NidusSpacing.sm) {
            header
            if model.isActive {
                running
            } else if model.isOnBreak {
                breakView
            } else {
                idle
            }
            // No trailing Spacer: the root frame already aligns to the top,
            // and the stack's spacing before a Spacer would add 8pt the
            // declared height does not have.
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.selectedCategoryIDs) { model.startProblem = nil }
        .onChange(of: model.categories) { model.startProblem = nil }
        .onChange(of: model.mode) { model.startProblem = nil }
    }

    // MARK: Header

    /// One header for every state: the menu bar's brain on its tile and a
    /// sans title, so nothing changes shape when a session starts or ends.
    private var header: some View {
        HStack(spacing: 11) {
            Image(nsImage: FocusGlyph.image(.brain, pointSize: 17))
                .renderingMode(.template)
                .foregroundStyle(model.isPaused || model.isOnBreak ? Solanum.inkMuted : Solanum.clayText)
                .frame(width: 35, height: 35)
                .background(Solanum.clay.opacity(0.12), in: .rect(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Solanum.clay.opacity(0.22)))
                .accessibilityHidden(true)
            Text(stateWord)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Solanum.ink)
            if model.isStrict || (model.strictMode && !model.isActive && !model.isOnBreak) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .help(model.isStrict ? "Strict session: no snooze or pause" : "Strict mode is on")
                    .accessibilityLabel(model.isStrict ? "Strict session" : "Strict mode on")
            }
            Spacer(minLength: 0)
            // Inside a sequence: where it stands, in one line.
            if let line = model.sequenceLine {
                Text(verbatim: line)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel("Sequence. " + line.replacingOccurrences(of: " \u{00B7} ", with: ", "))
            }
            if !model.isActive, !model.isOnBreak {
                Button(action: model.openSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Solanum.inkMuted)
                        .frame(width: 30, height: 30)
                        .background(Solanum.segmentWell, in: .circle)
                }
                .buttonStyle(.plain)
                .help("Nidus settings")
                .accessibilityLabel("Nidus settings")
            }
        }
        .frame(height: 38)
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
        VStack(alignment: .leading, spacing: 14) {
            // One nudge at a time: the most urgent, nothing otherwise. When
            // it is dismissed or handled the next one comes up.
            if nudge == .brick { BrickPopoverRow(model: model) }
            if nudge == .resume { ResumePopoverRow(model: model) }

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Overline("Your focus")
                    HStack(spacing: NidusSpacing.sm) {
                        TextField("What are you working on?", text: $model.goalDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Solanum.ink)
                            .focused($goalFocused)
                            .onSubmit(start)
                            .onKeyPress(.upArrow) { stepRecentGoal(1) }
                            .onKeyPress(.downArrow) { stepRecentGoal(-1) }
                            .accessibilityLabel("Goal")
                        if !model.recentGoals.isEmpty {
                            recentGoalsMenu
                        }
                    }
                    .frame(minHeight: 33)
                    if let clause = GoalLengthClause.split(model.goalDraft) { goalLengthChip(clause) }
                }
                .padding(.horizontal, 16)
                .padding(.top, 15)
                .padding(.bottom, 14)

                if model.offersProjectPicker || FocusSetupsBar.isVisible(model: model) {
                    Rectangle().fill(Solanum.hairline).frame(height: 1)
                    VStack(alignment: .leading, spacing: 10) {
                        if model.offersProjectPicker { FocusProjectPickerRow(model: model) }
                        if FocusSetupsBar.isVisible(model: model) { FocusSetupsBar(model: model) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(LinearGradient(colors: [Solanum.clay.opacity(0.10), Solanum.raised],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(goalFocused ? Solanum.clayText.opacity(0.7) : Solanum.hairline,
                              lineWidth: goalFocused ? 1.5 : 1))
            .onAppear {
                model.requestKeyboardFocus()
                // The calendar is read only when someone is about to start.
                model.refreshNextMeeting()
                DispatchQueue.main.async {
                    if model.customLengthDraft == nil { goalFocused = true } else { customLengthFocused = true }
                }
            }

            VStack(alignment: .leading, spacing: 11) {
                Overline("Session plan")
                HStack(spacing: NidusSpacing.sm) {
                    if model.customLengthDraft == nil { durationMenu } else { customLengthField }
                    categoryMenu
                    Spacer(minLength: 0)
                }
                if let draft = model.customLengthDraft { customLengthCaption(draft) }
                Rectangle().fill(Solanum.hairline).frame(height: 1)
                startButton
                if let problem = model.startProblem {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Solanum.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Session did not start. " + problem)
                }
            }
            .padding(15)
            .background(Solanum.segmentWell, in: .rect(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Solanum.hairline))
            // Return in the field, a choice from the Length menu or Escape
            // moves focus on: the field takes it when it opens, the goal
            // gets it back when it closes.
            .onChange(of: model.customLengthDraft != nil) { _, isOpen in
                if isOpen { focusCustomLengthField() } else { goalFocused = true }
            }

            if todayCache.line(for: model) != nil || nudge == .inbox || nudge == .saveSetup {
                HStack(spacing: NidusSpacing.sm) {
                    if let line = todayCache.line(for: model) {
                        Text(verbatim: line)
                            .font(.system(size: 12))
                            .foregroundStyle(Solanum.inkMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if nudge == .inbox { FocusInboxRow(model: model) }
                    if nudge == .saveSetup { saveSetupSuggestion }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    /// The one nudge the idle popover shows now.
    private var nudge: IdleNudge? {
        IdleNudge.top(brickOffer: model.currentBrickOffer != nil,
                      resumeNote: model.newestResumeNote != nil,
                      inbox: model.inboxOpenCount > 0,
                      saveSetup: model.offersSetupSuggestion())
    }

    /// Under the goal: the length read from its end, and the goal that will
    /// be kept, so a Start is never a surprise.
    private func goalLengthChip(_ clause: GoalLengthClause) -> some View {
        let length = clause.lengthLabel()
        return HStack(spacing: NidusSpacing.xs) {
            Image(systemName: "timer")
            Text(verbatim: "\(length) \u{00B7} goal saved as \u{201C}\(clause.goal)\u{201D}")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12))
        .foregroundStyle(Solanum.clayText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Length from the goal: \(length). The goal is saved as \(clause.goal).")
    }

    /// The quietest nudge: one line, offered when the same plan has been
    /// started by hand a few times. The cross ends the offer for that plan.
    private var saveSetupSuggestion: some View {
        HStack(spacing: NidusSpacing.xs) {
            Button(action: model.acceptSetupSuggestion) {
                Label("Save this as a setup", systemImage: "plus.square.on.square")
            }
            .help("Save this length and these categories as a setup")
            Button(action: model.dismissSetupSuggestion) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .help("Don\u{2019}t suggest this again")
            .accessibilityLabel("Don\u{2019}t suggest saving this setup again")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    /// Start, with any length still being typed taken first, as Return in
    /// the field would. If it cannot be read nothing starts: a session of a
    /// length nobody chose would block things for the wrong time.
    private func start() {
        guard model.commitCustomLength() else { return }
        model.startSession()
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
                .font(.system(size: 14))
                .foregroundStyle(Solanum.inkMuted)
                .frame(width: 30, height: 30)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
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
        let title = model.startTitle()
        let startsOnReturn = model.customLengthDraft == nil
        let blocksNothing = model.selectedCategories.allSatisfy(\.isEmpty) && model.mode == .block
        return Button(action: start) {
            HStack {
                Spacer(minLength: 0)
                Text(verbatim: title.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                // The arrow only when there is no Return hint: one mark, not two.
                if !(startsOnReturn && !blocksNothing) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 27)
            // The words keep clear of the Return hint, on both sides to
            // stay centred.
            .padding(.horizontal, 22)
            // Return starts, from the goal field too. Hidden while a length
            // is being typed, when Return belongs to that field.
            .overlay(alignment: .trailing) {
                if startsOnReturn && !blocksNothing {
                    Image(systemName: "return")
                        .font(.system(size: 11, weight: .medium))
                        .opacity(0.55)
                        .accessibilityHidden(true)
                }
            }
        }
            .buttonStyle(SolanumPrimaryButtonStyle(fontSize: 14))
            // While a length is being typed Return belongs to the field.
            .keyboardShortcut(startsOnReturn ? .defaultAction : nil)
            .disabled(blocksNothing)
            .help(startsOnReturn ? "Start a focus session (Return)" : "Start a focus session")
            .accessibilityLabel(title.spoken)
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
        HStack(spacing: NidusSpacing.xs) {
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
            Button("Edit categories…") { model.openSettings(.blocking) }
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
        HStack(spacing: NidusSpacing.xs) {
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
        VStack(alignment: .leading, spacing: NidusSpacing.sm) {
            if confirmingEnd, model.isStrict {
                strictEndRow
            } else {
                runningControls
            }
            if !model.isOpenEnded {
                progressBar
            }
            // "Save a thought" while it runs, and "Inbox · 3" when items wait.
            FocusInboxRow(model: model)
        }
        .onChange(of: model.isActive) { _, active in
            if !active { cancelStrictEnd() }
        }
        .onAppear { if model.harnessOpensStrictEnd { confirmingEnd = true } }
    }

    private var runningControls: some View {
        HStack(alignment: .bottom, spacing: NidusSpacing.md) {
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
            Spacer(minLength: NidusSpacing.md)
            HStack(spacing: NidusSpacing.sm) {
                if !model.isStrict { pauseButton }
                if !model.isOpenEnded {
                    Button {
                        model.addTime(minutes: NidusModel.addTimeMinutes(optionHeld: NSEvent.modifierFlags.contains(.option)))
                    } label: {
                        Text("+5")
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
                    // The same add as +5, so the 24-hour limit holds for all.
                    .contextMenu {
                        ForEach(NidusModel.addTimeSteps, id: \.self) { minutes in
                            Button("Add \(minutes) minutes") { model.addTime(minutes: minutes) }
                        }
                    }
                    .help("Add 5 minutes. Option-click adds 15; right-click for 5, 15 or 30. A session stops at 24 hours.")
                    .accessibilityLabel("Add 5 minutes")
                    .accessibilityAction(named: "Add 15 minutes") { model.addTime(minutes: 15) }
                    .accessibilityAction(named: "Add 30 minutes") { model.addTime(minutes: 30) }
                }
                Button {
                    if model.isStrict { confirmingEnd = true } else { model.endSession() }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
                .help(model.isStrict ? "End early" : (model.runningSequence == nil ? "End session" : "End sequence"))
                .accessibilityLabel(model.isStrict ? "End early" : (model.runningSequence == nil ? "End session" : "End sequence"))
            }
            .padding(.bottom, 8)
        }
    }

    /// A strict session ends early only after typing the phrase: enough to
    /// get past an impulse, not a lock.
    private var strictEndRow: some View {
        HStack(spacing: NidusSpacing.sm) {
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
    /// Start now and End. A break with rules says what stays blocked and
    /// until when, and shows its reminder. In a sequence the buttons start
    /// the next block and end the sequence.
    private var breakView: some View {
        VStack(alignment: .leading, spacing: NidusSpacing.sm) {
            HStack(alignment: .bottom, spacing: NidusSpacing.md) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: breakNextLine)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    breakClock(size: 44)
                }
                Spacer(minLength: NidusSpacing.md)
                HStack(spacing: NidusSpacing.sm) {
                    skipBreakButton
                    Button(action: model.endBreak) {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
                    .help(model.runningSequence == nil ? "Stop here: no session follows" : "End the sequence: no block follows")
                    .accessibilityLabel(model.runningSequence == nil ? "End the break" : "End the sequence")
                }
                .padding(.bottom, 8)
            }
            ProgressTrack(progress: model.breakProgress, tint: .gray)
            breakRestrictions
            FocusInboxRow(model: model)
        }
    }

    /// Above the break's clock: what starts after it. In a sequence the
    /// header already names the next block, so this says how far along it is.
    private var breakNextLine: String {
        if let run = model.runningSequence { return "Block \(run.blockNumber) of \(run.workCount) done" }
        return model.nextGoal.isEmpty ? "Next: another session" : "Next: \(model.nextGoal)"
    }

    /// What stays blocked until the break ends, and the note to self. Nothing
    /// is drawn for a break with neither, so an ordinary break looks as it did.
    @ViewBuilder
    private var breakRestrictions: some View {
        if let line = model.breakBlockedLine() {
            Label {
                Text(verbatim: line)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "nosign").frame(width: 14)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
        if let reminder = model.breakReminder {
            Label {
                Text(verbatim: reminder)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: NidusSymbols.rest).frame(width: 14)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Reminder: \(reminder)")
        }
    }

    private func breakClock(size: CGFloat) -> some View {
        Text(verbatim: model.clockText)
            .font(.system(size: size, weight: .light))
            .monospacedDigit()
            .foregroundStyle(AdaptiveColors.surfaceSecondaryText)
            .accessibilityLabel("Break, \(FocusFormat.spoken(model.breakRemaining))")
    }

    /// Labeled, so a play mark is not read as "resume" or "pause".
    private var skipBreakButton: some View {
        Button(action: model.skipBreak) {
            Label("Start now", systemImage: "play.fill")
        }
        .buttonStyle(.bordered).controlSize(.small)
        .help(model.runningSequence == nil ? "Start the next session now" : "Start the next block now")
    }

    private func clock(size: CGFloat) -> some View {
        Text(verbatim: model.clockText)
            .font(.system(size: size, weight: .light))
            .monospacedDigit()
            .foregroundStyle(model.isPaused ? AdaptiveColors.surfaceTertiaryText : AdaptiveColors.surfacePrimaryText)
            .accessibilityLabel(model.isOpenEnded
                ? "Focused for \(FocusFormat.spoken(model.elapsed).replacingOccurrences(of: " left", with: ""))"
                : FocusFormat.spoken(model.remaining))
    }

    private var pauseButton: some View {
        Button(action: model.togglePause) {
            Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                .id(model.isPaused)
                .transition(NidusTransition.element)
        }
        .buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
        .help(model.isPaused ? "Resume" : "Pause")
        .accessibilityLabel(model.isPaused ? "Resume" : "Pause")
    }

    private var progressBar: some View {
        ProgressTrack(progress: model.progress, tint: model.isPaused ? .gray : FocusPalette.clay)
    }
}

/// What the idle popover can nudge about. Several things may be waiting at
/// once and the popover shows one, so it stays a place to start.
enum IdleNudge: Equatable, CaseIterable {
    case brick, resume, inbox, saveSetup

    /// The most urgent of those waiting, in this order: a phone's request to
    /// focus (it goes stale), a note to pick up, the inbox, and last the
    /// offer to save the plan started by hand again and again. The project
    /// picker is not a nudge and is not asked about here.
    static func top(brickOffer: Bool, resumeNote: Bool, inbox: Bool, saveSetup: Bool = false) -> IdleNudge? {
        if brickOffer { return .brick }
        if resumeNote { return .resume }
        if inbox { return .inbox }
        if saveSetup { return .saveSetup }
        return nil
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

/// A session's progress, drawn here. The system's linear ProgressView kept
/// its fill gray with `.tint` set (see the running popover's render), so the
/// clay fill is drawn directly.
struct ProgressTrack: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let fraction = min(1, max(0, progress))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                if fraction > 0 {
                    Capsule().fill(tint).frame(width: geometry.size.width * fraction)
                }
            }
        }
        .frame(height: 6)
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
