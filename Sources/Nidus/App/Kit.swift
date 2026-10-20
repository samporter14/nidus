//
//  Kit.swift
//  Nidus
//
//  Nidus's UI toolkit: spacing, text colours, settings rows and card
//  requests, built from the Mac's standard controls. Settings is a grouped
//  form like System Settings, and clay is the accent.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Tokens

enum NidusSpacing {
    static let xs: CGFloat = 4
    static let xsm: CGFloat = 6
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
}

/// Text and fills in the popover and on the cards: the system's own.
enum AdaptiveColors {
    static var surfacePrimaryText: Color { .primary }
    static var surfaceSecondaryText: Color { .secondary }
    static var surfaceTertiaryText: Color { Color(nsColor: .tertiaryLabelColor) }
    static var surfaceCardFill: Color { Color(nsColor: .quaternaryLabelColor) }
}

enum NidusTransition {
    static var element: AnyTransition { .opacity.combined(with: .scale(scale: 0.9)) }
}

// MARK: - Settings rows

/// The whole of a settings page: a grouped form, as System Settings is.
struct NidusSettingsPane<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.settingsJump) private var jump
    @Environment(\.settingsPageID) private var page

    var body: some View {
        ScrollViewReader { scroll in
            Form { content() }
                .formStyle(.grouped)
                .tint(FocusPalette.clay)
                .task(id: jump?.destination) {
                    guard let destination = jump?.destination, destination.page == page else { return }
                    // Navigation can create this hosting view in the same turn.
                    // Wait for its first layout, without a repeating timer.
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    scroll.scrollTo(destination.anchor, anchor: .center)
                }
        }
    }
}

/// A page pushed from a link in Settings. The same as the pane.
typealias NidusSettingsPage = NidusSettingsPane

/// A heading over its rows. Cards inside it join its section.
struct NidusSettingsSection<Header: View, Content: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        Section {
            content()
        } header: {
            header()
        }
    }
}

/// A section's title, in the form's own heading style.
func settingsSectionHeader(_ title: String) -> some View {
    Text(title)
}

/// A section's title with a line under it saying what the section is for.
func settingsSectionHeader(_ title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        settingsSectionHeader(title)
        Text(detail)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }
}

/// One group of rows.
struct NidusSettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Section { content() }
    }
}

/// A title, an optional line under it, and a control on the right.
struct NidusControlRow<Accessory: View>: View {
    let title: String
    var infoTip: String?
    let accessory: Accessory

    init(title: String, icon: String? = nil, iconColor: Color? = nil, infoTip: String? = nil,
         accessoryAlignment: VerticalAlignment = .center, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.infoTip = infoTip
        self.accessory = accessory()
    }

    var body: some View {
        LabeledContent {
            accessory
        } label: {
            Text(title)
            if let infoTip { Text(infoTip) }
        }
    }
}

struct NidusToggleRow: View {
    let title: String
    var subtitle = ""
    @Binding var isOn: Bool

    init(title: String, icon: String? = nil, iconColor: Color? = nil, subtitle: String = "", isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
            if !subtitle.isEmpty { Text(subtitle) }
        }
        .toggleStyle(.switch)
    }
}

/// A title and line, with a pop-up menu (or any picker) on the right.
struct NidusGroupedPickerRow<PickerContent: View>: View {
    let title: String
    var subtitle = ""
    let picker: PickerContent

    init(title: String, icon: String? = nil, iconColor: Color? = nil, subtitle: String = "",
         @ViewBuilder picker: () -> PickerContent) {
        self.title = title
        self.subtitle = subtitle
        self.picker = picker()
    }

    var body: some View {
        LabeledContent {
            picker
                .labelsHidden()
                .fixedSize()
        } label: {
            Text(title)
            if !subtitle.isEmpty { Text(subtitle) }
        }
    }
}

/// A title with its content under it, full width.
struct NidusStackedRow<Content: View>: View {
    let title: String
    var infoTip: String?
    let content: Content

    init(title: String, icon: String? = nil, iconColor: Color? = nil, infoTip: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.infoTip = infoTip
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
            if let infoTip {
                Text(infoTip)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A short value, as a form shows one.
struct NidusValuePill: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}

/// A row that opens another page of Settings: a tile, a title and a line,
/// and a chevron, as System Settings' own.
struct NidusSettingsPageLink<Tile: View>: View {
    static var tileSize: CGFloat { 22 }

    let title: String
    let subtitle: String?
    let pageID: String
    let tile: Tile
    @Environment(SettingsRouter.self) private var router

    init(_ title: String, subtitle: String? = nil, page id: String, @ViewBuilder tile: () -> Tile) {
        self.title = title
        self.subtitle = subtitle
        self.pageID = id
        self.tile = tile()
    }

    var body: some View {
        Button {
            router.open(pageID, title: title)
        } label: {
            HStack(spacing: 10) {
                tile
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .foregroundStyle(.primary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(title)")
    }
}

/// A symbol on a small coloured tile, as System Settings draws its own.
struct SettingsTile: View {
    let image: Image
    var size: CGFloat = 22
    var color: Color = FocusPalette.clay

    init(symbol: String, size: CGFloat = 22, color: Color = FocusPalette.clay) {
        image = Image(systemName: symbol)
        self.size = size
        self.color = color
    }

    init(image: Image, size: CGFloat = 22, color: Color = FocusPalette.clay) {
        self.image = image
        self.size = size
        self.color = color
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color.gradient)
            .overlay(
                image
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Which page of Settings is showing, for the links and Back.
@MainActor @Observable
final class SettingsRouter {
    struct Page: Hashable {
        let id: String
        let title: String
    }

    var path: [Page] = []

    func open(_ id: String, title: String) {
        path.append(Page(id: id, title: title))
    }

    func back() {
        _ = path.popLast()
    }

    func reset(to id: String? = nil, title: String = "") {
        path = id.map { [Page(id: $0, title: title)] } ?? []
    }
}

// MARK: - Cards at the top of the screen

/// One card, measured from its content and shown for `duration` seconds.
/// The presenter replaces the card currently showing with this request.
struct HUDRequest {
    let id: String
    let duration: TimeInterval
    let accessibilityLabel: String
    let content: AnyView

    init<Content: View>(
        id: String,
        duration: TimeInterval,
        accessibilityLabel: String,
        @ViewBuilder content: () -> Content
    ) {
        self.id = id
        self.duration = duration
        self.accessibilityLabel = accessibilityLabel
        self.content = AnyView(content())
    }
}
