//
//  Kit.swift
//  Nidus
//
//  The small toolkit the views are written against: spacing, the card
//  colours, three button styles, the settings rows, and a card request. Nidus
//  began as a droplet for Droppy, and its views kept the names they had
//  there; everything here is Nidus's own.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Tokens

enum DroppySpacing {
    static let xs: CGFloat = 4
    static let xsm: CGFloat = 6
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
}

/// Text and fills on the cards and in the popover: Solanum's inks.
enum AdaptiveColors {
    static var notchSurfacePrimaryText: Color { Solanum.ink }
    static var notchSurfaceSecondaryText: Color { Solanum.inkMuted }
    static var notchSurfaceTertiaryText: Color { Solanum.inkFaint }
    static var notchSurfaceCardFill: Color { Solanum.segmentWell }
}

enum DroppyTransition {
    static var element: AnyTransition { .opacity.combined(with: .scale(scale: 0.9)) }
}

enum DroppyLiveActivityMetrics {
    static let iconSize: CGFloat = 13
    static let labelFontSize: CGFloat = 13
}

// MARK: - Buttons

enum DroppyButtonSize {
    case small, medium, large

    var fontSize: CGFloat {
        switch self {
        case .small: 12
        case .medium: 13
        case .large: 15
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .small: 12
        case .medium: 16
        case .large: 20
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .small: 5
        case .medium: 7
        case .large: 9
        }
    }
}

/// The everyday button: raised, with a control border, no fill colour.
struct DroppyQuietButtonStyle: ButtonStyle {
    var size: DroppyButtonSize = .medium
    var destructive = false

    init(size: DroppyButtonSize = .medium) { self.size = size }
    init(size: DroppyButtonSize, destructive: Bool) {
        self.size = size
        self.destructive = destructive
    }

    func makeBody(configuration: Configuration) -> some View {
        QuietBody(configuration: configuration, size: size, destructive: destructive)
    }

    private struct QuietBody: View {
        let configuration: Configuration
        let size: DroppyButtonSize
        let destructive: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: size.fontSize + 1, weight: .medium))
                .foregroundStyle(destructive ? Solanum.clayText : Solanum.ink)
                .padding(.horizontal, size.horizontalPadding)
                .padding(.vertical, size.verticalPadding)
                .background(configuration.isPressed || hovering ? Solanum.segmentWell : Solanum.raised,
                            in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isEnabled ? Solanum.strong : Solanum.hairline))
                .contentShape(.rect(cornerRadius: 8))
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { hovering = $0 }
        }
    }
}

/// A fill in one colour, for the one action that matters. On clay, and on
/// every other fill, the words are ink.
struct DroppyAccentButtonStyle: ButtonStyle {
    var color: Color = Solanum.clay
    var size: DroppyButtonSize = .medium

    func makeBody(configuration: Configuration) -> some View {
        AccentBody(configuration: configuration, color: color, size: size)
    }

    private struct AccentBody: View {
        let configuration: Configuration
        let color: Color
        let size: DroppyButtonSize
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: size.fontSize + 1, weight: .semibold))
                .foregroundStyle(Solanum.onClay.opacity(isEnabled ? 1 : 0.5))
                .padding(.horizontal, size.horizontalPadding + 2)
                .padding(.vertical, size.verticalPadding)
                .background(color.opacity(isEnabled ? 1 : 0.4), in: .rect(cornerRadius: 8))
                .brightness(configuration.isPressed ? -0.08 : 0)
                .contentShape(.rect(cornerRadius: 8))
        }
    }
}

/// A round icon button: raised, a hairline edge, an ink symbol.
struct DroppyCircleButtonStyle: ButtonStyle {
    var size: CGFloat = 32
    var destructive = false

    init(size: CGFloat = 32) { self.size = size }
    init(size: CGFloat, destructive: Bool, solidFill: Color?, foregroundColorOverride: Color?) {
        self.size = size
        self.destructive = destructive
    }

    func makeBody(configuration: Configuration) -> some View {
        CircleBody(configuration: configuration, size: size, destructive: destructive)
    }

    private struct CircleBody: View {
        let configuration: Configuration
        let size: CGFloat
        let destructive: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(destructive ? Solanum.clayText : Solanum.ink)
                .frame(width: size, height: size)
                .background(Circle().fill(configuration.isPressed || hovering ? Solanum.segmentWell : Solanum.raised))
                .overlay(Circle().strokeBorder(hovering ? Solanum.strong : Solanum.hairline))
                .contentShape(Circle())
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Settings rows

/// The whole of a settings page: scrolls, on the page colour.
struct DropletSettingsPane<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { content() }
                .padding(.horizontal, 32)
                .padding(.vertical, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Solanum.page)
    }
}

/// A page pushed from a link in Settings. The same as the pane.
typealias DropletSettingsPage = DropletSettingsPane

/// A heading over one or more cards.
struct DropletSettingsSection<Header: View, Content: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header().padding(.leading, 2)
            content()
        }
    }
}

/// A section's title: mono capitals, as Solanum's overlines are.
func settingsSectionHeader(_ title: String) -> some View {
    Overline(title)
}

typealias DropletSettingsCard = SettingsCard

struct DropletControlRow<Accessory: View>: View {
    let title: String
    var infoTip: String?
    @ViewBuilder let accessory: () -> Accessory

    init(title: String, icon: String? = nil, iconColor: Color? = nil, infoTip: String? = nil,
         accessoryAlignment: VerticalAlignment = .center, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.infoTip = infoTip
        let view = accessory()
        self.accessory = { view }
    }

    var body: some View {
        SettingsRow(title: title, hint: infoTip, trailing: accessory)
    }
}

struct DropletToggleRow: View {
    let title: String
    var subtitle = ""
    @Binding var isOn: Bool

    init(title: String, icon: String? = nil, iconColor: Color? = nil, subtitle: String = "", isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    var body: some View {
        SettingsRow(title: title, hint: subtitle.isEmpty ? nil : subtitle) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .tint(FocusPalette.clay)
                .labelsHidden()
        }
    }
}

struct DropletGroupedPickerRow<PickerContent: View>: View {
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
        SettingsRow(title: title, hint: subtitle.isEmpty ? nil : subtitle) {
            picker
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
        }
    }
}

/// A title with its control under it, full width.
struct DropletStackedRow<Content: View>: View {
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
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Solanum.ink)
            if let infoTip {
                Text(infoTip)
                    .font(.system(size: 12))
                    .foregroundStyle(Solanum.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A short value in a capsule.
struct DropletValuePill: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Solanum.inkMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Solanum.segmentWell))
            .overlay(Capsule().strokeBorder(Solanum.hairline))
    }
}

/// A row that opens another page of Settings.
struct DropletSettingsPageLink<Tile: View>: View {
    static var tileSize: CGFloat { 28 }

    let title: String
    let subtitle: String?
    let pageID: String
    let tile: Tile
    @Environment(SettingsRouter.self) private var router
    @State private var hovering = false

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
            HStack(spacing: 12) {
                tile
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Solanum.ink)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Solanum.inkMuted)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Solanum.inkFaint)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .frame(minHeight: 52)
            .background(hovering ? Solanum.segmentWell : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityHint("Opens \(title)")
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

/// One card: a short strip (unused off the notch) and the card itself,
/// shown for `duration` seconds. A card with the same id replaces it.
struct DropletHUDRequest {
    enum Priority { case normal, high }

    let id: String
    let duration: TimeInterval
    let priority: Priority
    let accessibilityLabel: String
    let height: CGFloat
    let content: AnyView

    init<Compact: View, Expanded: View>(
        id: String,
        duration: TimeInterval,
        priority: Priority = .normal,
        accessibilityLabel: String,
        isExpanded: Bool = true,
        expandedContentHeight: CGFloat = 64,
        @ViewBuilder compact: () -> Compact,
        @ViewBuilder expanded: () -> Expanded
    ) {
        self.id = id
        self.duration = duration
        self.priority = priority
        self.accessibilityLabel = accessibilityLabel
        self.height = expandedContentHeight
        self.content = AnyView(expanded())
    }
}
