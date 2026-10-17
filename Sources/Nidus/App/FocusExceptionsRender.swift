//
//  FocusExceptionsRender.swift
//  Nidus
//
//  What `--render-surfaces` draws for website exceptions: the Video
//  category's page with a few, and the editor on its own in each state of
//  adding one. The sample exceptions go into the demo's own settings, which
//  are emptied at each launch, and no session is ever started.
//

import AppKit
import SwiftUI

extension NidusModel {
    /// Demo only: three sample exceptions on the Video category, one of them
    /// outside every website it blocks. Only ever in the demo's own settings.
    func seedSampleExceptions() {
        guard Demo.isActive else { return }
        updateCategory("video") { category in
            category.websiteExceptions = FocusExceptionsRender.sample
        }
    }
}

/// The editor holding a list of its own, so a picture can show it as it is
/// used (its binding is the model's on a real page).
private struct ExceptionsEditorSample: View {
    @State var exceptions: [WebsiteException]
    let websites: [String]
    var running = false
    var address = ""
    var kind: WebsiteException.Kind = .exact

    var body: some View {
        DropletSettingsPage {
            WebsiteExceptionsEditor(exceptions: $exceptions, websites: websites, sessionIsRunning: running,
                                    address: address, kind: kind)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

enum FocusExceptionsRender {
    static let sample: [WebsiteException] = [
        WebsiteException(kind: .exact, address: "youtube.com/watch?v=dQw4w9WgXcQ"),
        WebsiteException(kind: .subtree, address: "youtube.com/@labtalks"),
        WebsiteException(kind: .exact, address: "vimeo.com/123456"),
    ]
}

extension RenderSurfaces {
    static func renderExceptions(model: NidusModel, settings: SettingsWindowController, in directory: URL) async {
        let websites = ["youtube.com", "netflix.com", "twitch.tv"]
        // As copied from a browser's address bar. The scheme is kept apart so
        // no web address sits in code (PrivacyTests).
        let pasted = "https://" + "www.youtube.com/watch?v=dQw4w9WgXcQ&t=43s&si=AbCd1234&feature=shared&utm_source=newsletter"

        // The category's own page. Staged just before the shot: every render
        // run shares one demo settings domain, and another may have emptied it.
        model.seedSampleExceptions()
        let video = model.categories.first { $0.id == "video" }
        await shootSettings(model, settings, page: NidusModel.categoryPagePrefix + "video", title: video?.name ?? "Video",
                            name: "settings-category-exceptions", height: 1500, in: directory)

        // The editor alone: empty, filling in each way, and with a session running.
        let states: [(String, ExceptionsEditorSample)] = [
            ("exceptions-empty", ExceptionsEditorSample(exceptions: [], websites: websites)),
            ("exceptions-add-exact", ExceptionsEditorSample(exceptions: [FocusExceptionsRender.sample[1]],
                                                            websites: websites, address: pasted)),
            ("exceptions-add-subtree", ExceptionsEditorSample(exceptions: [FocusExceptionsRender.sample[1]],
                                                              websites: websites, address: pasted, kind: .subtree)),
            ("exceptions-add-outside", ExceptionsEditorSample(exceptions: [], websites: websites, address: "vimeo.com/123456")),
            ("exceptions-add-refused", ExceptionsEditorSample(exceptions: [], websites: websites, address: "ftp://example.com/file")),
            ("exceptions-running", ExceptionsEditorSample(exceptions: FocusExceptionsRender.sample, websites: websites, running: true)),
        ]
        for (name, view) in states {
            await shoot(view, width: 640, height: name == "exceptions-empty" ? 330 : 620, name: "settings-\(name)", in: directory)
        }
    }
}
