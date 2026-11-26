//
//  CategoryTargetViews.swift
//  Nidus
//
//  A category's progress towards its daily target, as the Activity overview
//  and the popover's Today piece draw it: the words ("Work 2 hr 40 min of
//  4 hr") over a thin track filled in the category's own colour. Never clay:
//  clay means focus. Nothing moves, so Reduce Motion has nothing to turn off.
//

import SwiftUI

/// The Activity overview's targets: one row per category that has one.
struct CategoryTargetList: View {
    let rows: [CategoryTargetProgress]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Daily targets")
                .font(.solanum(.caption, weight: .medium))
                .foregroundStyle(Solanum.inkMuted)
            ForEach(rows) { row in
                CategoryTargetRow(progress: row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

struct CategoryTargetRow: View {
    let progress: CategoryTargetProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: progress.symbol)
                    .font(.solanum(.caption))
                    .foregroundStyle(Solanum.inkMuted)
                    .frame(width: 22, alignment: .leading)
                    .accessibilityHidden(true)
                Text(verbatim: progress.name)
                    .font(.solanum(.label))
                    .foregroundStyle(Solanum.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if progress.isMet {
                    Image(systemName: "checkmark")
                        .font(.solanum(.caption, weight: .semibold))
                        .foregroundStyle(Solanum.inkMuted)
                        .accessibilityHidden(true)
                }
                Text(verbatim: CategoryTargetProgress.amount(progress))
                    .font(.solanum(.caption, weight: .medium, design: .rounded))
                    .foregroundStyle(Solanum.inkMuted)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            SolanumMagnitudeBar(fraction: progress.fraction, color: ActivityInk.series(progress.tint))
                .padding(.leading, 31)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(progress.accessibilityText)
    }
}

/// The popover's one quiet line: the words, and the track under them.
struct CategoryTargetLine: View {
    let progress: CategoryTargetProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: progress.text)
                .font(.solanum(.label, weight: .regular))
                .foregroundStyle(Solanum.inkMuted)
                .lineLimit(1)
                .truncationMode(.tail)
            SolanumMagnitudeBar(fraction: progress.fraction, color: ActivityInk.series(progress.tint))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.accessibilityText)
    }
}
