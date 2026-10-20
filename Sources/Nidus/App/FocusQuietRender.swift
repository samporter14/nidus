//
//  FocusQuietRender.swift
//  Nidus
//
//  `--render-surfaces`: the ended card with Undo, and the Still paused card.
//

import SwiftUI

extension RenderSurfaces {
    static func renderQuietCards(model: NidusModel, host: NidusHost, in directory: URL) async {
        // Ended early: Undo stands where Again does, for the first seconds.
        model.runHarnessScenario("ended-undo")
        if let request = host.hud.lastRequest {
            await shoot(HUDCardView(content: request.content), width: HUDPresenter.width,
                        name: "card-ended-undo", in: directory, padded: true)
        }
        // After the window the card is as it was: Again.
        model.cards.endUndoOffer()
        if let request = host.hud.lastRequest {
            await shoot(HUDCardView(content: request.content), width: HUDPresenter.width,
                        name: "card-ended-again", in: directory, padded: true)
        }
        // A pause left for ten minutes.
        model.runHarnessScenario("still-paused")
        if let request = host.hud.lastRequest {
            await shoot(HUDCardView(content: request.content), width: HUDPresenter.width,
                        name: "card-still-paused", in: directory, padded: true)
        }
        model.runHarnessScenario("idle")
    }
}
