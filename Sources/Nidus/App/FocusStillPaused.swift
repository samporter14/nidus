//
//  FocusStillPaused.swift
//  Nidus
//
//  A pause the user chose and forgot: after ten minutes the engine says so
//  once (`SessionEvent.pauseLingering`) and this card asks, gently, whether to
//  Resume or End. It never resumes or ends anything by itself, and it does
//  not come back for the same pause.
//

import SwiftUI

extension NidusModel {
    static let stillPausedHUDID = "focus.still-paused"

    /// How long the reminder stays up. Long enough to be seen on returning to
    /// the Mac; it asks nothing and goes by itself.
    static let stillPausedDuration: TimeInterval = 30

    func presentStillPausedHUD() {
        guard let host, isPaused, !isStrict else { return }
        let left = FocusFormat.short(remaining)
        let request = HUDRequest(
            id: Self.stillPausedHUDID,
            duration: Self.stillPausedDuration,
            accessibilityLabel: "Still paused. \(FocusFormat.spoken(remaining)). Nothing is blocked while it is paused."
        ) { [weak self] in
            FocusStillPausedCard(detail: "\(left) \u{00B7} nothing is blocked",
                                 shortDetail: left,
                                 resume: {
                                     self?.togglePause()
                                     self?.host?.hud.dismiss(id: Self.stillPausedHUDID)
                                 },
                                 end: {
                                     self?.host?.hud.dismiss(id: Self.stillPausedHUDID)
                                     self?.endSession()
                                 })
        }
        if host.hud.present(request) {
            host.feedback.play(.tick)
        }
    }
}

/// "Still paused", with Resume and End. The longer line gives way first.
struct FocusStillPausedCard: View {
    let detail: String
    let shortDetail: String
    let resume: () -> Void
    let end: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(detail, last: false)
            row(shortDetail, last: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func row(_ detail: String, last: Bool) -> some View {
        HStack(alignment: .center, spacing: NidusSpacing.md) {
            if !last { SettingsTile(symbol: "pause.fill", size: 28) }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Still paused")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AdaptiveColors.surfacePrimaryText)
                Text(verbatim: detail)
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.surfaceSecondaryText)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: !last, vertical: false)
            Spacer(minLength: NidusSpacing.sm)
            Button("End", action: end)
                .buttonStyle(.bordered)
                .fixedSize()
                .accessibilityLabel("End the session")
            Button("Resume", action: resume)
                .buttonStyle(.borderedProminent)
                .tint(FocusPalette.clay)
                .fixedSize()
                .accessibilityLabel("Resume the session")
        }
    }
}
