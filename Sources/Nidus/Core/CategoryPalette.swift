//
//  CategoryPalette.swift
//  Nidus
//
//  Which of the eight chart hues a category or an app wears. A category keeps
//  its colour when the list is reordered, filtered or grows: a colour the user
//  picked is saved on the category, and one they didn't is worked out from the
//  categories' ids alone, never their positions. An app's colour comes from a
//  stable hash of its bundle id (or name), so Xcode is the same hue on every
//  day and in every chart.
//

import Foundation

enum CategoryPalette {
    /// How many hues there are (Solanum.seriesCount).
    static let count = 8

    /// A saved colour, or nil when it isn't one of the palette's slots.
    static func valid(_ slot: Int?) -> Int? {
        guard let slot, (0..<count).contains(slot) else { return nil }
        return slot
    }

    /// Each category's slot, by id. A saved colour wins. The rest are taken
    /// in id order: each gets its hash's slot, or the next one no category
    /// has yet, so two categories share a hue only when there are more than
    /// eight. Positions in the list never matter.
    static func slots(for categories: [FocusCategory]) -> [String: Int] {
        var result: [String: Int] = [:]
        var taken = Set<Int>()
        for category in categories {
            if let slot = valid(category.color) {
                result[category.id] = slot
                taken.insert(slot)
            }
        }
        let rest = categories.filter { valid($0.color) == nil }
            .map(\.id)
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .sorted()
        for id in rest {
            let preferred = slot(forKey: id)
            let free = (0..<count).map { (preferred + $0) % count }.first { !taken.contains($0) }
            let chosen = free ?? preferred
            result[id] = chosen
            taken.insert(chosen)
        }
        return result
    }

    /// The categories with every colour written down: what Settings saves,
    /// so a colour worked out once stays put however the list changes later.
    ///
    /// `previous` is the list as it was before this change: a category that
    /// already wore a colour there (saved or worked out) keeps it, so adding
    /// a category never repaints the ones already shown.
    static func fillingColors(of categories: [FocusCategory], keeping previous: [FocusCategory] = []) -> [FocusCategory] {
        let before = slots(for: previous)
        let kept = categories.map { category -> FocusCategory in
            var category = category
            if valid(category.color) == nil, let slot = before[category.id] { category.color = slot }
            return category
        }
        let resolved = slots(for: kept)
        return kept.map { category in
            var category = category
            if valid(category.color) == nil { category.color = resolved[category.id] }
            return category
        }
    }

    /// An app's (or any name's) slot: FNV-1a over its UTF-8, which unlike
    /// `hashValue` is the same in every launch.
    static func slot(forKey key: String) -> Int {
        Int(fnv1a(key) % UInt64(count))
    }

    static func fnv1a(_ key: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

/// What a chart's `tint: Int` means: a palette slot (0 and up), or one of
/// these two fixed meanings. Kept in Core so the day and week models can
/// hand tints to the views without knowing a colour.
enum ActivityTint {
    /// Time that belongs to no one thing: Other, Uncategorized.
    static let quiet = -1
    /// The Work group: work's own colour, not a palette slot.
    static let work = -2

    /// An app's tint: a stable slot from its bundle id, or its name.
    static func app(_ key: String) -> Int { CategoryPalette.slot(forKey: key) }
}
