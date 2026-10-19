//
//  Lossy.swift
//  Nidus
//
//  Reading saved lists one element at a time. A list that fails to decode as
//  a whole is read as empty, and the next save writes the empty list back:
//  one bad setup, or one history entry with a field a later version wrote
//  wrongly, would wipe every other. Lists read through here keep what still
//  decodes and drop only what doesn't.
//
//  Shared by the app and its tests.
//

import Foundation

/// An array decoded element by element; an element that fails is skipped.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]
    /// How many elements were skipped.
    var dropped: Int

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var dropped = 0
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                // A failed decode doesn't move the container on; this does.
                _ = try? container.decode(Skipped.self)
                dropped += 1
            }
        }
        self.elements = elements
        self.dropped = dropped
    }

    /// Decodes anything, keeping nothing.
    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

extension KeyedDecodingContainer {
    /// The array at `key`, element by element; missing or not an array is empty.
    func decodeLossy<Element: Decodable>(_ type: [Element].Type, forKey key: Key) -> [Element] {
        (try? decodeIfPresent(LossyArray<Element>.self, forKey: key))??.elements ?? []
    }

    /// The value at `key`, or nil when it is missing or doesn't decode. For
    /// fields added after 0.3, so one written wrongly loses only itself.
    func decodeTolerant<Value: Decodable>(_ type: Value.Type, forKey key: Key) -> Value? {
        (try? decodeIfPresent(Value.self, forKey: key)) ?? nil
    }
}

enum LossyJSON {
    /// A saved list, keeping every element that decodes. nil when the data
    /// isn't a list at all.
    static func list<Element: Decodable>(_ type: Element.Type, from data: Data) -> [Element]? {
        (try? JSONDecoder().decode(LossyArray<Element>.self, from: data))?.elements
    }
}
