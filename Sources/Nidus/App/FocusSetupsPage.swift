//
//  FocusSetupsPage.swift
//  Nidus
//
//  Settings, Setups: the list of saved setups, and a page for each one to
//  edit its name, symbol, length, what it blocks and whether it is strict.
//  Built from the rows in Kit.swift, like the category pages.
//

import SwiftUI

// MARK: - The list

struct FocusSetupsPage: View {
    @ObservedObject var model: NidusModel

    var body: some View {
        DropletSettingsPage {
            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Setups")
                    Text("Start a saved session in one click, from the popover or the right-click menu.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } content: {
                DropletSettingsCard {
                    ForEach(model.setups) { setup in
                        DropletSettingsPageLink(
                            setup.displayName,
                            subtitle: setup.problem(in: model.categories)?.reason
                                ?? setup.planSummary(categories: model.categories),
                            page: NidusModel.setupPagePrefix + setup.id.uuidString
                        ) {
                            CategoryTile(symbol: setup.symbol)
                        }
                    }
                    DropletControlRow(title: "New setup",
                                      infoTip: "Starts from the length and categories in the popover.") {
                        Button("Add") { model.addSetupFromCurrentChoices() }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}

extension FocusSettingsPane {
    /// The line under the Setups link on the main page.
    var setupsSummary: String {
        let names = model.setups.map(\.displayName)
        switch names.count {
        case 0: return "None yet"
        case 1, 2: return names.joined(separator: ", ")
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }
}

// MARK: - One setup

struct FocusSetupPage: View {
    @ObservedObject var model: NidusModel
    let setupID: FocusSetup.ID
    @FocusState private var nameFocused: Bool

    private var setup: FocusSetup? { model.setups.first { $0.id == setupID } }
    private var index: Int? { model.setups.firstIndex { $0.id == setupID } }

    var body: some View {
        DropletSettingsPage {
            if let setup {
                DropletSettingsCard {
                    DropletControlRow(title: "Name") {
                        TextField("Name", text: field(\.name))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .labelsHidden()
                            .focused($nameFocused)
                    }
                    DropletControlRow(title: "Symbol") {
                        SetupSymbolGrid(selection: field(\.symbol))
                    }
                }

                DropletSettingsSection {
                    settingsSectionHeader("Session")
                } content: {
                    DropletSettingsCard {
                        DropletGroupedPickerRow(title: "Length") {
                            Picker("Length", selection: field(\.minutes)) {
                                ForEach(lengthChoices(including: setup.minutes), id: \.self) { minutes in
                                    Text(FocusFormat.duration(minutes: minutes)).tag(minutes)
                                }
                            }
                        }
                        DropletControlRow(title: "Goal",
                                          infoTip: "Optional. A goal you type in the popover is used instead.") {
                            TextField("None", text: goal)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                                .labelsHidden()
                        }
                        DropletToggleRow(title: "Strict",
                                         subtitle: "No snooze or pause, and ending early means typing \u{201C}stop early\u{201D} in the popover.",
                                         isOn: field(\.strict))
                    }
                }

                DropletSettingsSection {
                    VStack(alignment: .leading, spacing: 2) {
                        settingsSectionHeader("Blocking")
                        Text("Pick one or more categories.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } content: {
                    DropletSettingsCard {
                        DropletGroupedPickerRow(title: "What to block",
                                                subtitle: "Block the categories you pick, or block everything except them.") {
                            Picker("What to block", selection: field(\.mode)) {
                                Text("Block list").tag(SessionPlan.Mode.block)
                                Text("Allow list").tag(SessionPlan.Mode.allow)
                            }
                            .pickerStyle(.segmented)
                        }
                        ForEach(model.categories) { category in
                            // One line each; only an empty category says so,
                            // since it can't block anything.
                            Toggle(isOn: includes(category)) {
                                // Symbols differ in width; a fixed column keeps the names in line.
                                Label {
                                    Text(category.name)
                                } icon: {
                                    Image(systemName: category.symbol).frame(width: 22)
                                }
                                if category.isEmpty { Text("Empty") }
                            }
                            .toggleStyle(.switch)
                        }
                        if let problem = setup.problem(in: model.categories) {
                            Label("\(problem.reason). It won\u{2019}t start until you pick a category with apps or websites.",
                                  systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        } else if setup.mode == .allow, setup.liveCategoryIDs(in: model.categories).isEmpty {
                            Label("Nothing is allowed, so every app and website is blocked.",
                                  systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                DropletSettingsCard {
                    DropletControlRow(title: "Order", infoTip: "Where it sits in the popover and the menu.") {
                        HStack(spacing: DroppySpacing.sm) {
                            moveButton("Move up", symbol: "chevron.up", step: -1, enabled: (index ?? 0) > 0)
                            moveButton("Move down", symbol: "chevron.down", step: 1,
                                       enabled: (index ?? 0) < model.setups.count - 1)
                        }
                    }
                    DropletControlRow(title: "Delete this setup") {
                        Button("Delete", role: .destructive) { model.deleteSetup(setupID) }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
        .onAppear {
            // A setup just made is still called "New setup": the one thing
            // to do here is name it.
            guard setup?.name == FocusSetup.defaultName else { return }
            DispatchQueue.main.async { nameFocused = true }
        }
    }

    // MARK: Bindings

    /// A field of the setup, written back as it changes.
    private func field<Value>(_ keyPath: WritableKeyPath<FocusSetup, Value>) -> Binding<Value> {
        Binding(
            get: { (setup ?? FocusSetup())[keyPath: keyPath] },
            set: { value in model.updateSetup(setupID) { $0[keyPath: keyPath] = value } }
        )
    }

    /// The goal is nil, not empty, when cleared.
    private var goal: Binding<String> {
        Binding(
            get: { setup?.goal ?? "" },
            set: { text in model.updateSetup(setupID) { $0.goal = text.isEmpty ? nil : text } }
        )
    }

    /// Whether a category is in the setup. Turning one on or off also drops
    /// ids of categories deleted since, which is the one time the list is
    /// tidied.
    private func includes(_ category: FocusCategory) -> Binding<Bool> {
        Binding(
            get: { setup?.categoryIDs.contains(category.id) ?? false },
            set: { on in
                model.updateSetup(setupID) { setup in
                    var ids = setup.liveCategoryIDs(in: model.categories).filter { $0 != category.id }
                    if on { ids.append(category.id) }
                    setup.categoryIDs = ids
                }
            }
        )
    }

    /// The same lengths as Session length, and the setup's own if it is
    /// something else, so the picker never loses what it holds.
    private func lengthChoices(including minutes: Int) -> [Int] {
        NidusModel.durationChoices.contains(minutes) ? NidusModel.durationChoices : [minutes] + NidusModel.durationChoices
    }

    private func moveButton(_ label: String, symbol: String, step: Int, enabled: Bool) -> some View {
        Button {
            model.moveSetup(setupID, by: step)
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Symbols

/// A setup's symbol, picked from a small grid.
struct SetupSymbolGrid: View {
    @Binding var selection: String

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 6), spacing: 6) {
            ForEach(FocusSetup.symbols, id: \.symbol) { choice in
                let isSelected = selection == choice.symbol
                Button {
                    selection = choice.symbol
                } label: {
                    Image(systemName: choice.symbol)
                        .font(.system(size: 15))
                        .frame(width: 34, height: 28)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary)))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.5))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(choice.name)
                .accessibilityLabel(choice.name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .fixedSize()
    }
}
