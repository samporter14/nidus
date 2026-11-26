import AppKit
import SwiftUI

/// "Show what's blocked": closed, it is one label and holds nothing. Opening it
/// builds the list; closing it, or the popover going away, drops the list.
struct BlockedListDisclosure: View {
    let build: () -> BlockedList?
    @State private var state = LazyBlockedList()

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { state.expanded },
                                            set: { state.setExpanded($0, build: build) })) {
            if let list = state.list {
                BlockedListContentView(list: list)
                    .padding(.top, 6)
            }
        } label: {
            Text(verbatim: state.list?.mode == .allow ? "Show what's allowed" : "Show what's blocked")
        }
        .font(.solanum(.label, weight: .regular))
        .foregroundStyle(Solanum.inkMuted)
        .tint(Solanum.clayText)
        .onDisappear { state.reset() }
    }
}

struct BlockedListContentView: View {
    let list: BlockedList

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let line = list.differenceLine {
                Label { Text(verbatim: line).fixedSize(horizontal: false, vertical: true) }
                    icon: { Image(systemName: "arrow.triangle.branch").accessibilityHidden(true) }
            }
            if list.isEmpty {
                Text("Nothing listed.")
            }
            ForEach(list.sections) { section in
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: section.title).font(.solanum(.label, weight: .semibold))
                    ForEach(section.apps) { app in
                        HStack(spacing: 6) {
                            BlockedAppIcon(bundleID: app.bundleID)
                            Text(verbatim: app.name)
                            if app.neverBlocked {
                                Text("never blocked").font(.solanum(.caption)).foregroundStyle(Solanum.inkMuted)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    ForEach(section.websites, id: \.self) { site in
                        HStack(spacing: 6) {
                            Image(systemName: "globe").frame(width: 16).accessibilityHidden(true)
                            Text(verbatim: site)
                        }
                    }
                }
            }
        }
        .font(.solanum(.label, weight: .regular))
    }
}

/// The app's icon at 16 pt, looked up when the row appears and gone with it.
private struct BlockedAppIcon: View {
    let bundleID: String
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable() } else { Image(systemName: "app").foregroundStyle(Solanum.inkMuted) }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
        .onAppear {
            guard icon == nil, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
            let image = NSWorkspace.shared.icon(forFile: url.path)
            image.size = NSSize(width: 16, height: 16)
            icon = image
        }
        .onDisappear { icon = nil }
    }
}
