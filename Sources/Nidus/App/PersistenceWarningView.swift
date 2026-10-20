import SwiftUI

/// Normally absent. A durability failure stays visible until the pending
/// changes are written successfully; retry never discards the in-memory copy.
struct PersistenceWarningView: View {
    @ObservedObject var persistence: PersistenceCoordinator
    @State private var retrying = false

    var body: some View {
        if !persistence.failures.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(Solanum.clayText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Changes haven’t been saved")
                        .font(.system(size: 12, weight: .semibold))
                    Text(persistence.failures.map(\.label).joined(separator: ", ")
                         + ". Your changes remain in memory while Nidus is open.")
                        .font(.system(size: 11))
                        .foregroundStyle(Solanum.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(retrying ? "Retrying…" : "Retry") {
                    retrying = true
                    persistence.retryFailedWrites()
                    Task { @MainActor in
                        _ = await persistence.flush()
                        retrying = false
                    }
                }
                .buttonStyle(.borderless)
                .disabled(retrying)
                .accessibilityLabel("Retry saving changes")
            }
            .padding(10)
            .background(Solanum.segmentWell, in: .rect(cornerRadius: 10))
            .accessibilityElement(children: .contain)
        }
    }
}
