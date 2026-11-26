import Foundation
import Testing
@testable import Nidus

/// Stable chart colours: a category keeps its hue however the list changes,
/// an app's hue comes from its id, and a saved colour decodes tolerantly.
@Suite("Category palette")
struct CategoryPaletteTests {
    private func category(_ id: String, color: Int? = nil) -> FocusCategory {
        var category = FocusCategory(id: id, name: id, symbol: "circle", apps: [], websites: [])
        category.color = color
        return category
    }

    @Test func reorderingKeepsEveryColour() {
        let list = ["social", "video", "news", "games", "shopping"].map { category($0) }
        let forward = CategoryPalette.slots(for: list)
        let backward = CategoryPalette.slots(for: list.reversed())
        let shuffled = CategoryPalette.slots(for: [list[3], list[0], list[4], list[2], list[1]])
        #expect(forward == backward)
        #expect(forward == shuffled)
    }

    @Test func filteringDoesNotRepaintTheRest() {
        // Removing one category can free its hue, but never moves another's
        // unless that other one had been pushed off its own hash slot.
        let list = ["a", "b", "c"].map { category($0) }
        let all = CategoryPalette.slots(for: list)
        let fewer = CategoryPalette.slots(for: Array(list.prefix(2)))
        for id in ["a", "b"] where all[id] == CategoryPalette.slot(forKey: id) {
            #expect(fewer[id] == all[id])
        }
    }

    @Test func upToEightCategoriesNeverShareAHue() {
        let list = (0..<8).map { category("category-\($0)") }
        let slots = CategoryPalette.slots(for: list)
        #expect(Set(slots.values).count == 8)
        #expect(slots.values.allSatisfy { (0..<CategoryPalette.count).contains($0) })
    }

    @Test func aChosenColourWinsAndIsNotHandedOut() {
        let preferred = CategoryPalette.slot(forKey: "video")
        let list = [category("social", color: preferred), category("video")]
        let slots = CategoryPalette.slots(for: list)
        #expect(slots["social"] == preferred)
        #expect(slots["video"] != preferred)
    }

    @Test func outOfRangeColoursAreIgnored() {
        #expect(CategoryPalette.valid(8) == nil)
        #expect(CategoryPalette.valid(-1) == nil)
        #expect(CategoryPalette.valid(3) == 3)
        let slots = CategoryPalette.slots(for: [category("x", color: 42)])
        #expect(slots["x"] == CategoryPalette.slot(forKey: "x"))
    }

    @Test func fillingColorsWritesEveryColourDown() {
        let list = [category("social", color: 2), category("video"), category("news")]
        let filled = CategoryPalette.fillingColors(of: list)
        #expect(filled.allSatisfy { $0.color != nil })
        #expect(filled[0].color == 2)
        let resolved = CategoryPalette.slots(for: list)
        #expect(filled.map(\.color) == list.map { resolved[$0.id] })
        // Once written down, adding a category changes none of them.
        let grown = CategoryPalette.slots(for: filled + [category("aaa-first-by-id")])
        for item in filled { #expect(grown[item.id] == item.color) }
    }

    @Test func appSlotsAreStableAndCaseBlind() {
        #expect(CategoryPalette.slot(forKey: "com.apple.dt.Xcode") == CategoryPalette.slot(forKey: "COM.APPLE.DT.XCODE"))
        // FNV-1a, not hashValue: the same in every launch.
        #expect(CategoryPalette.fnv1a("") == 0xcbf2_9ce4_8422_2325)
        #expect(CategoryPalette.fnv1a("a") == 0xaf63_dc4c_8601_ec8c)
        let keys = ["com.apple.Safari", "com.tinyspeck.slackmacgap", "com.apple.dt.Xcode", "md.obsidian", "com.microsoft.Word"]
        for key in keys { #expect((0..<8).contains(CategoryPalette.slot(forKey: key))) }
        #expect(Set(keys.map { ActivityTint.app($0) }).count > 1)
    }

    @Test func colourDecodesTolerantly() throws {
        func decode(_ color: String) throws -> FocusCategory {
            let json = #"{"id":"social","name":"Social","symbol":"person.2","apps":[],"websites":[],"color":\#(color)}"#
            return try JSONDecoder().decode(FocusCategory.self, from: Data(json.utf8))
        }
        #expect(try decode("5").color == 5)
        #expect(try decode("\"teal\"").color == nil)
        #expect(try decode("99").color == nil)
        #expect(try decode("null").color == nil)
        let old = #"{"id":"social","name":"Social","symbol":"person.2","apps":[],"websites":[]}"#
        let decoded = try JSONDecoder().decode(FocusCategory.self, from: Data(old.utf8))
        #expect(decoded.color == nil)
        #expect(decoded.name == "Social")
    }

    @Test func colourRoundTrips() throws {
        let saved = category("social", color: 6)
        let back = try JSONDecoder().decode(FocusCategory.self, from: JSONEncoder().encode(saved))
        #expect(back.color == 6)
    }

    @Test func categorizerTintsFollowColoursNotOrder() {
        let work = FocusCategory.workSeed
        let a = category("social", color: 1), b = category("video", color: 4)
        let one = ActivityCategorizer(categories: [a, b], work: work)
        let two = ActivityCategorizer(categories: [b, a], work: work)
        #expect(one.tint(of: "social") == 1)
        #expect(two.tint(of: "social") == 1)
        #expect(one.tint(of: "video") == 4)
        #expect(one.tint(of: ActivityCategorizer.workID) == ActivityTint.work)
        #expect(one.tint(of: nil) == ActivityTint.quiet)
        #expect(one.tint(of: "gone") == ActivityTint.quiet)
    }
}
