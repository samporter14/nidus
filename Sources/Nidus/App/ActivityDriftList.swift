//
//  ActivityDriftList.swift
//  Nidus
//
//  The shown range's drift chains, what came before and what took over, with
//  how often and for how long. Only what was recorded is named. Each row
//  carries a 4 pt bar for how long it took next to the longest.
//

import SwiftUI

struct ActivityDriftList: View {
    let chains: [ActivityDriftChain]
    let categorizer: ActivityCategorizer
    @Environment(\.colorSchemeContrast) private var contrast

    static let emptyMessage = "Drift shows here when focus slips to something else"

    var body: some View {
        if chains.isEmpty {
            placeholder
        } else {
            let longest = max(1, chains.map(\.seconds).max() ?? 1)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(chains) { chain in
                    let color = ActivityInk.series(categorizer.tint(of: chain.category))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(color)
                                .frame(width: 6, height: 6)
                            Text(verbatim: "\(chain.origin) \u{2192} \(chain.target)")
                                .foregroundStyle(Solanum.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(verbatim: "\(chain.times), \(ActivityDuration.string(chain.seconds))")
                                .foregroundStyle(Solanum.inkMuted)
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .font(.solanum(.caption))
                        SolanumMagnitudeBar(fraction: chain.seconds / longest, color: color)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("From \(chain.origin) to \(chain.target), \(chain.times), \(ActivityDuration.string(chain.seconds)), \(categorizer.label(of: chain.category).name)")
                }
            }
        }
    }

    /// The list's real frame with nothing in it: three rows of empty track.
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(Solanum.track(contrast)).frame(width: 6, height: 6)
                        RoundedRectangle(cornerRadius: Solanum.markRadius)
                            .fill(Solanum.track(contrast))
                            .frame(maxWidth: 180, minHeight: 10, maxHeight: 10)
                        Spacer(minLength: 8)
                    }
                    .frame(height: 14)
                    SolanumMagnitudeBar(fraction: 0, color: Solanum.track(contrast))
                }
            }
        }
        .chartEmptyState(true, Self.emptyMessage)
    }
}
