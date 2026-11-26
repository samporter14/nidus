//
//  ActivitySortCard.swift
//  Nidus
//
//  "Sort uncategorized" on the Activity page: the longest uncategorized apps
//  and websites in the range, each with Work, a category, or Leave. Every
//  choice is a "Count as" override (`NidusModel.countActivity`), so it
//  changes how time is counted and never what a session blocks. A sorted
//  item leaves the card when the page reloads for the new overrides.
//

import SwiftUI

struct ActivitySortCard: View {
    @ObservedObject var model: NidusModel
    let items: [ActivityUncategorizedItem]
    var shown = 6

    var body: some View {
        if !items.isEmpty {
            NidusSettingsSection {
                VStack(alignment: .leading, spacing: 3) {
                    settingsSectionHeader("Sort uncategorized")
                    Text("Where should these count? It changes Activity only, never what a session blocks.")
                        .font(.solanum(.label, weight: .regular))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } content: {
                NidusSettingsCard {
                    ForEach(items.prefix(shown)) { item in
                        ActivitySortRow(model: model, item: item)
                    }
                    if items.count > shown {
                        Text("\(items.count - shown) more")
                            .font(.solanum(.caption))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.top, 2)
                    }
                }
            }
        }
    }
}

private struct ActivitySortRow: View {
    @ObservedObject var model: NidusModel
    let item: ActivityUncategorizedItem
    /// For a subdomain: count the whole registrable domain, not just the host.
    @State private var wholeDomain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            row
            if let domain = item.domain {
                Picker("Applies to", selection: $wholeDomain) {
                    Text(verbatim: "Just \(item.name)").tag(false)
                    Text(verbatim: "All of \(domain)").tag(true)
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .padding(.leading, 27)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.name), \(ActivityDuration.string(item.seconds)) uncategorized")
    }

    private var row: some View {
        HStack(spacing: 9) {
            Image(systemName: item.isWebsite ? "globe" : "app.dashed")
                .font(.solanum(.caption))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
                .accessibilityHidden(true)
            Text(verbatim: item.name)
                .font(.solanum(.label))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(ActivityDuration.string(item.seconds))
                .font(.solanum(.caption, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button(model.workGroup.name) { count(.work) }
                .help("Count \(item.name) as \(model.workGroup.name)")
            Menu("Category") {
                ForEach(model.categories) { category in
                    Button(category.name) { count(.category(category.id)) }
                }
            }
            .menuIndicator(.visible)
            .fixedSize()
            .disabled(model.categories.isEmpty)
            .help("Count \(item.name) under one of your categories")
            Button("Leave") { count(.uncategorized) }
                .help("Keep \(item.name) uncategorized and stop asking")
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
    }

    private func count(_ group: ActivityGroup) {
        let subject = item.subject(wholeDomain: wholeDomain)
        switch subject {
        case .domain(let domain):
            model.countActivity(subject: subject, name: "\(domain) and subdomains", as: group)
            return
        case .page(let page):
            model.countActivity(subject: subject, name: page.title, as: group)
            return
        case .app, .site:
            break
        }
        model.countActivity(appID: item.appID, appName: item.appName, site: item.site, url: item.url, as: group)
    }
}
