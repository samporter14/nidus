//
//  CategoryColourPicker.swift
//  Nidus
//
//  The Colour row of the category editor: the eight chart hues as swatches.
//  Activity and Stats draw the category in whichever is chosen. It never
//  changes what a session blocks.
//

import SwiftUI

struct CategoryColourPicker: View {
    @Binding var selection: Int
    @Environment(\.colorSchemeContrast) private var contrast

    static let hint = "Activity draws this category in this colour."

    /// "Colour, Teal", the words VoiceOver reads for a swatch; "selected"
    /// comes from the trait.
    static func label(forSlot slot: Int) -> String {
        let names = Solanum.seriesNames
        return "Colour, " + names[((slot % names.count) + names.count) % names.count]
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<Solanum.seriesCount, id: \.self) { slot in
                let chosen = slot == selection
                Button { selection = slot } label: {
                    Circle()
                        .fill(Solanum.series(slot))
                        .frame(width: 16, height: 16)
                        .padding(3)
                        .overlay {
                            if chosen { Circle().strokeBorder(Solanum.ink, lineWidth: 2) }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(Solanum.seriesNames[slot])
                .accessibilityLabel(Self.label(forSlot: slot))
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Colour")
    }
}
