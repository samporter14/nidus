//
//  BreakRulesEditor.swift
//  Nidus
//
//  What a break keeps blocked, chosen the way a session's blocking is: the
//  categories (one switch each), then any other apps and websites one by one,
//  then a reminder. It edits a `BreakRules` through a binding and knows
//  nothing about where the rules live, so Settings uses it for the default
//  rules, a sequence's break for its own, and a setup can use it for its
//  break. Its rows are meant to sit inside a `NidusSettingsCard`.
//

import AppKit
import SwiftUI

struct BreakRulesEditor: View {
    @Binding var rules: BreakRules
    let categories: [FocusCategory]
    @State private var newWebsite = ""

    var body: some View {
        Group {
            ForEach(categories) { category in
                // One line each; only an empty category says so, since it
                // can't block anything.
                Toggle(isOn: includes(category)) {
                    Label {
                        Text(category.name)
                    } icon: {
                        Image(systemName: category.symbol).frame(width: 22)
                    }
                    if category.isEmpty { Text("Empty") }
                }
                .toggleStyle(.switch)
            }
            ForEach(extras.apps, id: \.self) { bundleID in
                NidusControlRow(title: BreakRulesNames.app(bundleID, categories: categories)) {
                    removeButton("Remove \(BreakRulesNames.app(bundleID, categories: categories))") {
                        rules = rules.removing(app: bundleID)
                    }
                }
            }
            ForEach(extras.websites, id: \.self) { site in
                NidusControlRow(title: site) {
                    removeButton("Remove \(site)") { rules = rules.removing(website: site) }
                }
            }
            NidusControlRow(title: "Other apps") {
                Button("Choose apps…", action: chooseApps)
                    .buttonStyle(.bordered)
            }
            NidusControlRow(title: "Other website") {
                HStack(spacing: NidusSpacing.sm) {
                    TextField("example.com", text: $newWebsite)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .labelsHidden()
                        .onSubmit(addWebsite)
                    Button("Add", action: addWebsite)
                        .buttonStyle(.bordered)
                        .disabled(FocusCategory.domain(from: newWebsite) == nil)
                }
            }
            NidusControlRow(title: "Reminder",
                              infoTip: "A note to yourself, shown while the break runs.") {
                TextField("Stretch, water", text: reminder)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .labelsHidden()
                    .accessibilityLabel("Break reminder")
            }
            Text(Self.caption(for: rules, categories: categories))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// What the rules come to, in a line under the rows.
    static func caption(for rules: BreakRules, categories: [FocusCategory]) -> String {
        guard let names = rules.blockedNames(categories: categories, appName: { BreakRulesNames.app($0, categories: categories) }) else {
            return "The break blocks nothing."
        }
        return "Blocked during the break: \(BreakRules.list(names).text)."
    }

    private var extras: (apps: [String], websites: [String]) { rules.extras(in: categories) }

    private func includes(_ category: FocusCategory) -> Binding<Bool> {
        Binding(
            get: { rules.covers(category) },
            set: { rules = rules.setting(category, on: $0, in: categories) }
        )
    }

    private var reminder: Binding<String> {
        Binding(
            get: { rules.reminder ?? "" },
            set: { rules = rules.settingReminder($0) }
        )
    }

    private func addWebsite() {
        rules = rules.adding(website: newWebsite)
        newWebsite = ""
    }

    private func chooseApps() {
        let apps = AppChooser.choose(title: "Choose apps to block during a break")
        rules = rules.adding(apps: apps.map(\.bundleID))
    }

    private func removeButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Names for bundle identifiers, where a break's rules are shown.
enum BreakRulesNames {
    /// The name a category holds for it, else the installed app's, else the
    /// identifier itself.
    @MainActor
    static func app(_ bundleID: String, categories: [FocusCategory]) -> String {
        if let known = categories.lazy.flatMap(\.apps).first(where: { $0.bundleID == bundleID }) { return known.name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return bundleID
    }
}
