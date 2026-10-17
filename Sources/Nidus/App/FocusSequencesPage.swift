//
//  FocusSequencesPage.swift
//  Nidus
//
//  Settings, Setups: the Sequences section under the setups, and a page for
//  each sequence to edit its name and its steps. A step is a work block (a
//  goal, a length, and optionally a setup and a project) or a break (a length
//  and what stays blocked). Steps are added, removed and reordered with
//  buttons, so everything is reachable from the keyboard. Built from the rows
//  in Kit.swift, like the setup pages.
//

import SwiftUI

// MARK: - The list

/// The Sequences section of the Setups tab: each saved sequence with its
/// summary, and an Add.
struct FocusSequencesSection: View {
    @ObservedObject var model: NidusModel

    var body: some View {
        DropletSettingsSection {
            settingsSectionHeader("Sequences",
                                  detail: "Different blocks and breaks in a row, started in one click: 40 minutes of writing, a 10 minute break, then 25 minutes of figures.")
        } content: {
            DropletSettingsCard {
                ForEach(model.sequences) { sequence in
                    DropletSettingsPageLink(
                        sequence.displayName,
                        subtitle: model.problem(of: sequence)?.message ?? sequence.summary(setups: model.setups),
                        page: NidusModel.sequencePagePrefix + sequence.id.uuidString
                    ) {
                        CategoryTile(symbol: FocusSequencesMenu.symbol)
                    }
                }
                DropletControlRow(title: "New sequence",
                                  infoTip: "Starts as a block, a break and a block, which you can change.") {
                    Button("Add") { model.addSequence() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }
}

// MARK: - One sequence

struct FocusSequencePage: View {
    @ObservedObject var model: NidusModel
    let sequenceID: FocusSequence.ID
    @FocusState private var nameFocused: Bool

    private var sequence: FocusSequence? { model.sequences.first { $0.id == sequenceID } }
    private var index: Int? { model.sequences.firstIndex { $0.id == sequenceID } }

    var body: some View {
        DropletSettingsPage {
            if let sequence {
                DropletSettingsCard {
                    DropletControlRow(title: "Name") {
                        TextField("Name", text: nameBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .labelsHidden()
                            .focused($nameFocused)
                    }
                }

                plan(sequence)

                ForEach(Array(sequence.steps.enumerated()), id: \.element.id) { offset, step in
                    stepSection(step, at: offset, of: sequence)
                }

                DropletSettingsCard {
                    DropletControlRow(title: "Add a step") {
                        HStack(spacing: DroppySpacing.sm) {
                            Button("Work block") { append(.work()) }
                            Button("Break") { append(.rest()) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(sequence.steps.count >= FocusSequence.stepLimit)
                    }
                }

                DropletSettingsCard {
                    DropletControlRow(title: "Start this sequence",
                                      infoTip: startNote(for: sequence)) {
                        Button("Start") { model.startSequence(sequence) }
                            .buttonStyle(.borderedProminent)
                            .tint(FocusPalette.clay)
                            .disabled(!canStart(sequence))
                    }
                    DropletControlRow(title: "Order", infoTip: "Where it sits in the popover and the menu.") {
                        HStack(spacing: DroppySpacing.sm) {
                            iconButton("Move sequence up", symbol: "chevron.up", enabled: (index ?? 0) > 0) {
                                model.moveSequence(sequenceID, by: -1)
                            }
                            iconButton("Move sequence down", symbol: "chevron.down",
                                       enabled: (index ?? 0) < model.sequences.count - 1) {
                                model.moveSequence(sequenceID, by: 1)
                            }
                        }
                    }
                    DropletControlRow(title: "Delete this sequence") {
                        Button("Delete", role: .destructive) { model.deleteSequence(sequenceID) }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
        .onAppear {
            // A sequence just made is still called "New sequence": the one
            // thing to do first is name it.
            guard sequence?.name == FocusSequence.defaultName else { return }
            DispatchQueue.main.async { nameFocused = true }
        }
    }

    // MARK: The plan

    /// What the sequence comes to, and what stops it from starting.
    private func plan(_ sequence: FocusSequence) -> some View {
        DropletSettingsSection {
            settingsSectionHeader("Plan")
        } content: {
            DropletSettingsCard {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: sequence.steps.isEmpty ? "No steps yet" : sequence.summary(setups: model.setups))
                        .fixedSize(horizontal: false, vertical: true)
                    if !sequence.steps.isEmpty {
                        Text(verbatim: sequence.totals())
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                ForEach(Array(sequence.problems(in: model.sequenceContext).enumerated()), id: \.offset) { _, problem in
                    Label(problem.message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func canStart(_ sequence: FocusSequence) -> Bool {
        model.problem(of: sequence) == nil && model.canStartNew
    }

    private func startNote(for sequence: FocusSequence) -> String {
        if let problem = model.problem(of: sequence) { return problem.message }
        if !model.canStartNew { return "Not while a session or break is on." }
        return "Resolved when it starts: changing this sequence or a setup afterwards leaves a run alone."
    }

    // MARK: A step

    private func stepSection(_ step: FocusSequence.Step, at offset: Int, of sequence: FocusSequence) -> some View {
        let number = offset + 1
        let kind = step.isWork ? "Work block" : "Break"
        return DropletSettingsSection {
            HStack(spacing: DroppySpacing.sm) {
                Text(verbatim: "\(number) \u{00B7} \(kind)")
                Spacer(minLength: DroppySpacing.sm)
                iconButton("Move step \(number) up", symbol: "chevron.up", enabled: offset > 0) {
                    update { $0.steps = FocusSequence.moving(step.id, by: -1, in: $0.steps) }
                }
                iconButton("Move step \(number) down", symbol: "chevron.down", enabled: offset < sequence.steps.count - 1) {
                    update { $0.steps = FocusSequence.moving(step.id, by: 1, in: $0.steps) }
                }
                iconButton("Remove step \(number)", symbol: "minus.circle", enabled: true) {
                    update { $0.steps.removeAll { $0.id == step.id } }
                }
            }
        } content: {
            DropletSettingsCard {
                if step.isWork { workRows(step) } else { breakRows(step, in: sequence) }
            }
        }
    }

    @ViewBuilder
    private func workRows(_ step: FocusSequence.Step) -> some View {
        DropletControlRow(title: "Goal",
                          infoTip: "Optional. Empty takes the setup\u{2019}s goal, if it has one.") {
            TextField("None", text: stepField(step, \.goal))
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .labelsHidden()
                .accessibilityLabel("Goal of step \(number(of: step))")
        }
        DropletGroupedPickerRow(title: "Length") {
            Picker("Length", selection: stepField(step, \.minutes)) {
                ForEach(choices(FocusSequence.workChoices, including: step.minutes), id: \.self) { minutes in
                    Text(FocusFormat.duration(minutes: minutes)).tag(minutes)
                }
            }
        }
        DropletGroupedPickerRow(title: "Setup",
                                subtitle: step.setupID == nil
                                    ? "None: blocks what the popover has chosen."
                                    : "Blocks what the setup does, strict or not.") {
            Picker("Setup", selection: stepField(step, \.setupID)) {
                Text("None").tag(UUID?.none)
                ForEach(model.setups) { setup in
                    Text(setup.displayName).tag(UUID?.some(setup.id))
                }
                if let missing = step.setupID, !model.setups.contains(where: { $0.id == missing }) {
                    Text("Deleted setup").tag(UUID?.some(missing))
                }
            }
        }
        let projects = model.projects.filter { !$0.isArchived || $0.id == step.projectID }
        if !projects.isEmpty {
            DropletGroupedPickerRow(title: "Project") {
                Picker("Project", selection: stepField(step, \.projectID)) {
                    Text("None").tag(UUID?.none)
                    ForEach(projects) { project in
                        Text(project.displayName).tag(UUID?.some(project.id))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func breakRows(_ step: FocusSequence.Step, in sequence: FocusSequence) -> some View {
        DropletGroupedPickerRow(title: "Length") {
            Picker("Length", selection: stepField(step, \.minutes)) {
                ForEach(choices(FocusSequence.breakChoices, including: step.minutes), id: \.self) { minutes in
                    Text(FocusFormat.duration(minutes: minutes)).tag(minutes)
                }
            }
        }
        DropletGroupedPickerRow(title: "Blocked during the break",
                                subtitle: Self.subtitle(for: step.rules)) {
            Picker("Blocked during the break", selection: ruleChoice(step)) {
                Text("As the next block\u{2019}s setup").tag(RuleChoice.inherit)
                Text("Nothing").tag(RuleChoice.none)
                Text("Its own rules").tag(RuleChoice.own)
            }
        }
        if case .own = step.rules {
            BreakRulesEditor(rules: ownRules(step), categories: model.categories)
        }
    }

    private enum RuleChoice: Hashable { case inherit, none, own }

    static func subtitle(for choice: FocusSequence.Step.BreakChoice) -> String {
        switch choice {
        case .inherit: return "What the next block\u{2019}s setup says, or Settings\u{2019} break rules."
        case .none: return "The break blocks nothing."
        case .own: return "Its own rules, below."
        }
    }

    private func ruleChoice(_ step: FocusSequence.Step) -> Binding<RuleChoice> {
        Binding(
            get: {
                switch currentStep(step)?.rules ?? step.rules {
                case .inherit: return .inherit
                case .none: return .none
                case .own: return .own
                }
            },
            set: { choice in
                updateStep(step) { current in
                    switch choice {
                    case .inherit: current.rules = .inherit
                    case .none: current.rules = .none
                    case .own:
                        // Starts from what it would have inherited nothing of:
                        // an empty rule set the person fills in.
                        if case .own = current.rules {} else { current.rules = .own(BreakRules()) }
                    }
                }
            }
        )
    }

    private func ownRules(_ step: FocusSequence.Step) -> Binding<BreakRules> {
        Binding(
            get: {
                if case .own(let rules)? = currentStep(step)?.rules { return rules }
                return BreakRules()
            },
            set: { rules in updateStep(step) { $0.rules = .own(rules) } }
        )
    }

    // MARK: Bindings and editing

    private var nameBinding: Binding<String> {
        Binding(
            get: { sequence?.name ?? "" },
            set: { name in model.updateSequence(sequenceID) { $0.name = name } }
        )
    }

    private func update(_ change: (inout FocusSequence) -> Void) {
        model.updateSequence(sequenceID, change)
    }

    private func append(_ step: FocusSequence.Step) {
        update { sequence in
            guard sequence.steps.count < FocusSequence.stepLimit else { return }
            sequence.steps.append(step)
        }
    }

    private func currentStep(_ step: FocusSequence.Step) -> FocusSequence.Step? {
        sequence?.steps.first { $0.id == step.id }
    }

    private func updateStep(_ step: FocusSequence.Step, _ change: @escaping (inout FocusSequence.Step) -> Void) {
        update { sequence in
            guard let at = sequence.steps.firstIndex(where: { $0.id == step.id }) else { return }
            change(&sequence.steps[at])
        }
    }

    /// A field of a step, written back as it changes. A step is found by its
    /// id each time, so one moved or removed meanwhile is not written to.
    private func stepField<Value>(_ step: FocusSequence.Step, _ keyPath: WritableKeyPath<FocusSequence.Step, Value>) -> Binding<Value> {
        Binding(
            get: { (currentStep(step) ?? step)[keyPath: keyPath] },
            set: { value in updateStep(step) { $0[keyPath: keyPath] = value } }
        )
    }

    private func number(of step: FocusSequence.Step) -> Int {
        (sequence?.steps.firstIndex { $0.id == step.id } ?? 0) + 1
    }

    /// The usual lengths, and the step's own if it is something else, so the
    /// picker never loses what it holds.
    private func choices(_ usual: [Int], including minutes: Int) -> [Int] {
        usual.contains(minutes) ? usual : ([minutes] + usual).sorted()
    }

    private func iconButton(_ label: String, symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }
}
