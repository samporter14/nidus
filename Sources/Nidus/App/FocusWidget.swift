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
                .foregroundStyle(model.isActive && !model.isPaused ? Solanum.clayText : Solanum.inkFaint)
                .accessibilityHidden(true)
            Overline(stateWord)
            if model.isStrict || (model.strictMode && !model.isActive && !model.isOnBreak) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Solanum.inkFaint)
                    .help(model.isStrict ? "Strict session: no snooze or pause" : "Strict mode is on")
                    .accessibilityLabel(model.isStrict ? "Strict session" : "Strict mode on")
            }
            Spacer(minLength: 0)
            if !model.isActive, !model.isOnBreak {
                Button(action: model.openSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 26))
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

    private var idle: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.md) {
            HStack(spacing: DroppySpacing.sm) {
                TextField("What are you working on?", text: $model.goalDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(Solanum.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Solanum.raised, in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Solanum.strong, lineWidth: goalFocused ? 2 : 1))
                    .focused($goalFocused)
                    .onSubmit(model.startSession)
                    .onKeyPress(.upArrow) { stepRecentGoal(1) }
                    .onKeyPress(.downArrow) { stepRecentGoal(-1) }
                    .accessibilityLabel("Goal")
                if !model.recentGoals.isEmpty {
                    recentGoalsMenu
                }
            }
            .onAppear {
                model.requestKeyboardFocus()
                DispatchQueue.main.async { goalFocused = true }
            }

            HStack(spacing: DroppySpacing.sm) {
                durationMenu
                categoryMenu
                Spacer(minLength: DroppySpacing.sm)
                startButton
            }
        }
    }

    private var compactIdle: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            startButton
            Text(verbatim: "\(FocusFormat.duration(minutes: model.durationMinutes)) · \(model.selectionSummary)")
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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Solanum.ink)
                .frame(width: 36, height: 36)
                .background(Solanum.raised, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Solanum.strong))
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
        Button("Start", action: model.startSession)
            .buttonStyle(DroppyAccentButtonStyle(size: .small))
            .keyboardShortcut(.defaultAction)
            .disabled(model.selectedCategories.allSatisfy(\.isEmpty) && model.mode == .block)
            .help("Start a focus session")
    }

    private var durationMenu: some View {
        Menu {
            ForEach(NidusModel.durationChoices, id: \.self) { minutes in
                Toggle(FocusFormat.duration(minutes: minutes), isOn: Binding(
                    get: { model.durationMinutes == minutes },
                    set: { if $0 { model.durationMinutes = minutes } }
                ))
            }
        } label: {
            menuLabel(FocusFormat.duration(minutes: model.durationMinutes), symbol: "timer")
        }
        .menuStyle(.button)
        .buttonStyle(DroppyQuietButtonStyle(size: .small))
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Length")
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
        .buttonStyle(DroppyQuietButtonStyle(size: .small))
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(model.mode == .allow ? "Allowed categories" : "Blocked categories")
    }

    private func menuLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: DroppySpacing.xs) {
            Image(systemName: symbol)
            Text(verbatim: title).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
        }
    }

    // MARK: Running

    /// The clock, the controls and the progress bar. The bar ends 13pt above
    /// the bottom edge, clear of the clipped corners.
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
                    .foregroundStyle(model.goal.isEmpty ? Solanum.inkMuted : Solanum.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                clock(size: 44)
            }
            Spacer(minLength: DroppySpacing.md)
            HStack(spacing: DroppySpacing.sm) {
                if !model.isStrict { pauseButton }
                if !model.isOpenEnded {
                    Button(action: model.addTime) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(DroppyCircleButtonStyle(size: 30))
                    .help("Add 5 minutes")
                    .accessibilityLabel("Add 5 minutes")
                }
                Button {
                    if model.isStrict { confirmingEnd = true } else { model.endSession() }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 30))
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
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
                .fixedSize()
            Button("End", action: confirmStrictEnd)
                .buttonStyle(DroppyAccentButtonStyle(size: .small))
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
                        .foregroundStyle(Solanum.inkMuted)
                        .lineLimit(1)
                    breakClock(size: 44)
                }
                Spacer(minLength: DroppySpacing.md)
                HStack(spacing: DroppySpacing.sm) {
                    skipBreakButton(size: 30)
                    Button(action: model.endBreak) {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(DroppyCircleButtonStyle(size: 30))
                    .help("Stop here: no session follows")
                    .accessibilityLabel("End the break")
                }
                .padding(.bottom, 8)
            }
            ProgressTrack(progress: model.breakProgress, fill: Solanum.inkFaint)
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
            .font(Solanum.serif(size))
            .monospacedDigit()
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            .accessibilityLabel("Break, \(FocusFormat.spoken(model.breakRemaining))")
    }

    private func skipBreakButton(size: CGFloat) -> some View {
        Button(action: model.skipBreak) {
            Image(systemName: "play.fill")
        }
        .buttonStyle(DroppyCircleButtonStyle(size: size))
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
            .font(Solanum.serif(size))
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
        .buttonStyle(DroppyCircleButtonStyle(size: context.isCompact ? 20 : 30))
        .help(model.isPaused ? "Resume" : "Pause")
        .accessibilityLabel(model.isPaused ? "Resume" : "Pause")
    }

    private var progressBar: some View {
        ProgressTrack(progress: model.progress, fill: model.isPaused ? Solanum.inkFaint : Solanum.clay)
    }
}

/// A session's progress: a hairline well, filled in clay.
struct ProgressTrack: View {
    let progress: Double
    let fill: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Solanum.segmentWell)
                Capsule().strokeBorder(Solanum.hairline)
                Capsule()
                    .fill(fill)
                    .frame(width: max(6, proxy.size.width * min(1, max(0, progress))))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

extension NidusModel {
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
