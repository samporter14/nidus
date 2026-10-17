//
//  WebsiteExceptionsEditor.swift
//  Nidus
//
//  The "Exceptions" section of a page that holds blocked websites: pages let
//  through although a website above blocks them. Built to be dropped into any
//  such page (a category's now, a saved setup's later): it takes the list to
//  edit and the website rules that list sits inside, and knows nothing of the
//  model.
//
//  Adding is three small steps in the open: paste an address, choose how much
//  of the site it lets through, read the sentence that says exactly what
//  that is, then add. What is saved is what the sentence described
//  (Core/WebsiteException+Matching.swift makes both from one reading).
//

import SwiftUI

struct WebsiteExceptionsEditor: View {
    @Binding var exceptions: [WebsiteException]
    /// The website rules these exceptions sit inside; the ones that no rule
    /// blocks are flagged, since they would do nothing.
    let websites: [String]
    /// True while a session is running: it keeps the exceptions it started
    /// with, so the section says that changes wait for the next one.
    var sessionIsRunning = false

    @State private var address: String
    @State private var kind: WebsiteException.Kind
    @FocusState private var addressFocused: Bool

    init(exceptions: Binding<[WebsiteException]>, websites: [String], sessionIsRunning: Bool = false,
         address: String = "", kind: WebsiteException.Kind = .exact) {
        _exceptions = exceptions
        self.websites = websites
        self.sessionIsRunning = sessionIsRunning
        _address = State(initialValue: address)
        _kind = State(initialValue: kind)
    }

    private var attempt: Result<WebsiteExceptionDraft, WebsiteExceptionProblem> {
        WebsiteException.draft(from: address, kind: kind)
    }

    var body: some View {
        DropletSettingsSection {
            VStack(alignment: .leading, spacing: 2) {
                settingsSectionHeader("Exceptions")
                Text("Let one page through while the rest of a blocked website stays blocked.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } content: {
            DropletSettingsCard {
                ForEach(exceptions) { exception in
                    DropletControlRow(title: exception.displayAddress, infoTip: detail(of: exception)) {
                        Button {
                            exceptions.removeAll { $0 == exception }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove the exception for \(exception.displayAddress)")
                        .accessibilityLabel("Remove the exception for \(exception.displayAddress)")
                    }
                }
                DropletControlRow(title: exceptions.isEmpty ? "No exceptions yet" : "Add another") {
                    TextField("Paste a page address", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                        .labelsHidden()
                        .focused($addressFocused)
                        .onSubmit(add)
                        .accessibilityLabel("Address of the page to let through")
                }
                if !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    adding
                }
                if sessionIsRunning {
                    Text("A session that is running keeps the exceptions it started with. Changes apply to the next one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Adding

    @ViewBuilder
    private var adding: some View {
        switch attempt {
        case .failure(let problem):
            if let message = problem.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        case .success(let draft):
            DropletGroupedPickerRow(title: "Let through") {
                Picker("Let through", selection: $kind) {
                    ForEach(WebsiteException.Kind.choices, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(draft.summary)
                ForEach(draft.details, id: \.self) { line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(draft.warnings, id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !draft.isReachable(by: websites) {
                    Label("None of the websites above blocks this page, so it would change nothing.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if exceptions.contains(draft.exception) {
                    Text("Already an exception.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer(minLength: 0)
                    Button("Add exception", action: add)
                        .buttonStyle(.bordered)
                        .disabled(exceptions.contains(draft.exception))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
        }
    }

    private func add() {
        guard case .success(let draft) = attempt, !exceptions.contains(draft.exception) else { return }
        exceptions.append(draft.exception)
        address = ""
        kind = .exact
        addressFocused = true
    }

    /// The line under a listed exception: the sentence the preview showed
    /// when it was added, and a word when it would do nothing.
    private func detail(of exception: WebsiteException) -> String {
        guard let rule = exception.rule else { return "Not a web address, so it does nothing." }
        var line = rule.summary
        if !rule.isReachable(by: websites) { line += " No website above blocks it, so it does nothing." }
        return line
    }
}
