//
//  FocusSetupsBar.swift
//  Nidus
//
//  The popover's row of saved setups: a small button for each, which starts
//  it at once, with whatever goal is typed above. A few sit in the row; the
//  rest go under More. A plus saves the popover's current choices as a new
//  setup. It goes in the popover's idle view, above the length and
//  categories.
//

import SwiftUI

struct FocusSetupsBar: View {
    @ObservedObject var model: NidusModel

    init(model: NidusModel) {
        self.model = model
    }

    /// Up to this many fill the row. Past it, the first three stay and the
    /// rest go under More, so the row never runs out of width.
    static let inlineLimit = 4
    static let inlineWhenMore = 3

    /// Whether the bar has anything to show. With no setups it is nothing at
    /// all, not an empty row: the popover's own controls stay as they were,
    /// and a first setup is made in Settings or from the menu there.
    static func isVisible(model: NidusModel) -> Bool {
        !model.setups.isEmpty
    }

    /// Which sit in the row and which go under More.
    static func split(_ setups: [FocusSetup]) -> (inline: [FocusSetup], overflow: [FocusSetup]) {
        guard setups.count > inlineLimit else { return (setups, []) }
        return (Array(setups.prefix(inlineWhenMore)), Array(setups.dropFirst(inlineWhenMore)))
    }

    private var inline: [FocusSetup] { Self.split(model.setups).inline }
    private var overflow: [FocusSetup] { Self.split(model.setups).overflow }

    var body: some View {
        if Self.isVisible(model: model) {
            HStack(spacing: DroppySpacing.xsm) {
                ForEach(inline) { setupButton($0) }
                if !overflow.isEmpty { moreMenu }
                Spacer(minLength: DroppySpacing.sm)
                saveButton
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Setups

    private func setupButton(_ setup: FocusSetup) -> some View {
        let problem = setup.problem(in: model.categories)
        return Button {
            model.start(setup)
        } label: {
            Label(setup.displayName, systemImage: setup.symbol)
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .disabled(problem != nil)
        .help(help(for: setup, problem: problem))
        .accessibilityLabel("Start \(setup.displayName)")
        .accessibilityHint(problem?.reason ?? setup.planSummary(categories: model.categories))
        .contextMenu {
            Button("Edit…") { model.openSetupPage(setup) }
            Button("Copy Launch Link") { model.copyLaunchLink(for: setup) }
        }
    }

    private func help(for setup: FocusSetup, problem: FocusSetup.Problem?) -> String {
        if let problem { return "\(problem.reason). Edit it to choose again." }
        return "\(setup.displayName): \(setup.planSummary(categories: model.categories))"
    }

    private var moreMenu: some View {
        Menu {
            ForEach(overflow) { setup in
                let problem = setup.problem(in: model.categories)
                Button {
                    model.start(setup)
                } label: {
                    Label(setup.displayName, systemImage: setup.symbol)
                }
                .disabled(problem != nil)
                .help(help(for: setup, problem: problem))
            }
            Divider()
            Button("Edit setups…", action: model.openSetupsPage)
        } label: {
            Text("More")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
        .accessibilityLabel("More setups")
    }

    // MARK: Saving

    /// Icon only: with four setups beside it there is no room for words.
    private var saveButton: some View {
        Button {
            model.addSetupFromCurrentChoices()
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .help("Save as setup…")
        .accessibilityLabel("Save as setup")
    }
}
