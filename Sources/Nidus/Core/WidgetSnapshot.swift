//
//  WidgetSnapshot.swift
//  Nidus
//
//  `widget.json` in Nidus's folder: what the desktop widget and the Control
//  Center controls show (Widget/NidusWidget.swift). The app writes it when
//  the session or the setups change; the widget, sandboxed, may only read
//  that folder. Nothing in it leaves the Mac. Compiled into both the app and
//  the widget extension.
//

import Foundation

struct WidgetSnapshot: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case idle, focusing, paused, onBreak }

    struct Setup: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var name: String
        var symbol: String
    }

    static let fileName = "widget.json"
    /// How many setups the widget can show.
    static let setupLimit = 4

    var version = 1
    var state: State = .idle
    var goal: String = ""
    /// When the session or break ends, seconds since 1970. nil when idle,
    /// paused or open-ended.
    var endsAt: Double?
    /// Of a paused session.
    var secondsLeft: Double?
    var strict = false
    var setups: [Setup] = []

    var endDate: Date? { endsAt.map(Date.init(timeIntervalSince1970:)) }

    /// The links the widget's buttons open: Nidus does the rest, under the
    /// same rules as any nidus:// link (a strict session can't be ended).
    static func startURL(setupID: String) -> URL {
        var components = URLComponents()
        components.scheme = "nidus"
        components.host = "start"
        components.queryItems = [URLQueryItem(name: "preset", value: setupID)]
        return components.url!
    }

    static let endURL = URL(string: "nidus://end")!
    static let popoverURL = URL(string: "nidus://popover")!
}
