//
//  ActivityDriftList.swift
//  Nidus
//
//  The shown range's drift chains, what came before and what took over, with
//  how often and for how long. Only what was recorded is named.
//

import SwiftUI

struct ActivityDriftList: View {
    let chains: [ActivityDriftChain]
    let categorizer: ActivityCategorizer

    var body: some View {
        if chains.isEmpty {
            Text("No drift in this range.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(chains) { chain in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(ActivityInk.series(categorizer.order(of: chain.category) ?? ActivityInk.quietTint))
                            .frame(width: 6, height: 6)
                        Text(verbatim: "\(chain.origin) \u{2192} \(chain.target)")
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(verbatim: "\(chain.times), \(ActivityDuration.string(chain.seconds))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .font(.system(size: 11))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("From \(chain.origin) to \(chain.target), \(chain.times), \(ActivityDuration.string(chain.seconds)), \(categorizer.label(of: chain.category).name)")
                }
            }
        }
    }
}
