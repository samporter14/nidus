//
//  FocusCalendar.swift
//  Nidus
//
//  "Until next meeting": a session length that ends when your next timed
//  event today begins. Calendar is read on this Mac with EventKit, only
//  after a click, and only when asked: nothing polls, and nothing about an
//  event is stored, logged or sent anywhere.
//
//  The calendar is a protocol, so the rules are tested with a fake and a
//  demo, render or test never asks for access.
//

import Combine
import EventKit
import SwiftUI

// MARK: - The calendar

/// An event, as far as Nidus reads it: copied out of EventKit at once.
struct CalendarEvent: Equatable, Sendable {
    var title: String
    var start: Date
    var end: Date
    var isAllDay = false
    /// You declined it.
    var isDeclined = false
    var isCancelled = false
}

/// The next meeting today.
struct Meeting: Equatable, Sendable {
    var title: String
    var start: Date

    /// The next timed event that starts after `now` and before the day ends,
    /// skipping all-day events, cancelled ones and any you declined. An event
    /// that has started is not next, even if it has not ended.
    static func next(after now: Date, in events: [CalendarEvent], calendar: Calendar) -> Meeting? {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return nil }
        return events
            .filter { !$0.isAllDay && !$0.isDeclined && !$0.isCancelled && $0.start > now && $0.start < tomorrow }
            .min { ($0.start, $0.title) < ($1.start, $1.title) }
            .map { Meeting(title: $0.title, start: $0.start) }
    }

    /// "Until 2:00 PM (Design review)", with a long title cut short.
    var menuTitle: String {
        let time = start.formatted(date: .omitted, time: .shortened)
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Until \(time)" }
        let shown = name.count > 28 ? name.prefix(27) + "…" : Substring(name)
        return "Until \(time) (\(shown))"
    }
}

enum CalendarAccess: Equatable, Sendable {
    /// Never asked; the first click asks.
    case notDetermined
    case authorized
    /// Refused, restricted, or write-only. macOS asks only once, so there is
    /// nothing to offer but System Settings.
    case unavailable
}

@MainActor
protocol CalendarSource: AnyObject {
    var access: CalendarAccess { get }
    /// Shows macOS's own prompt, the first time. Call it only from a click.
    func requestAccess() async -> Bool
    /// Empty unless access was granted.
    func events(from start: Date, to end: Date) -> [CalendarEvent]
}

/// Calendar on this Mac. The store is made on first use, so opening Nidus
/// touches nothing, and in a demo, render or capture it is never made.
@MainActor
final class EventKitCalendarSource: CalendarSource {
    private var store: EKEventStore?

    var access: CalendarAccess {
        guard !Demo.isActive else { return .unavailable }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .fullAccess: return .authorized
        default: return .unavailable
        }
    }

    func requestAccess() async -> Bool {
        guard !Demo.isActive, access == .notDetermined else { return access == .authorized }
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        // A store made before access was granted keeps reading nothing.
        self.store = granted ? EKEventStore() : nil
        return granted
    }

    func events(from start: Date, to end: Date) -> [CalendarEvent] {
        guard access == .authorized else { return [] }
        let store = self.store ?? EKEventStore()
        self.store = store
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map { event in
            CalendarEvent(
                title: event.title ?? "",
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                isDeclined: event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false,
                isCancelled: event.status == .canceled
            )
        }
    }
}

/// A calendar that answers from a list. For the tests and the renders, which
/// must never ask for real access.
@MainActor
final class FakeCalendarSource: CalendarSource {
    var access: CalendarAccess
    var events: [CalendarEvent]
    /// What the prompt would answer.
    var grants: Bool
    private(set) var requestCount = 0

    init(access: CalendarAccess = .authorized, events: [CalendarEvent] = [], grants: Bool = true) {
        self.access = access
        self.events = events
        self.grants = grants
    }

    func requestAccess() async -> Bool {
        requestCount += 1
        if access == .notDetermined { access = grants ? .authorized : .unavailable }
        return access == .authorized
    }

    func events(from start: Date, to end: Date) -> [CalendarEvent] {
        access == .authorized ? events.filter { $0.start < end && $0.end > start } : []
    }
}

// MARK: - The next meeting

/// The next meeting today, looked up when asked, and the one-shot choice of
/// "Until next meeting" as the popover's length.
@MainActor
final class MeetingFinder {
    var source: CalendarSource
    var calendar: Calendar = .autoupdatingCurrent
    private(set) var next: Meeting?
    /// The popover's length is "until next meeting". It lasts until a session
    /// starts or a fixed length is picked, so it never goes stale.
    var isChosen = false
    var didChange: () -> Void = {}
    private var cancellables: Set<AnyCancellable> = []

    init(source: CalendarSource = EventKitCalendarSource()) {
        self.source = source
    }

    var access: CalendarAccess { source.access }

    /// Picking a fixed length takes the choice back.
    func start(preferenceChanges: PassthroughSubject<String, Never>?, didChange: @escaping () -> Void) {
        self.didChange = didChange
        preferenceChanges?
            .filter { $0 == NidusModel.Key.durationMinutes }
            .sink { [weak self] _ in self?.isChosen = false }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        didChange = {}
    }

    /// Looks the next meeting up now. It reads nothing without access, and
    /// never asks for it.
    func refresh(now: Date = Date()) {
        var meeting: Meeting?
        if source.access == .authorized, let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) {
            meeting = Meeting.next(after: now, in: source.events(from: now, to: tomorrow), calendar: calendar)
        }
        guard meeting != next else { return }
        next = meeting
        didChange()
    }

    /// Asks macOS for access, if never asked, then looks. From a click only.
    @discardableResult
    func requestAccess(now: Date = Date()) async -> Bool {
        let granted = await source.requestAccess()
        refresh(now: now)
        didChange()
        return granted
    }

    /// Whole minutes to the next meeting if it is at least a minute away: what
    /// the menu offers, and what a session can end at.
    func offeredMinutes(now: Date = Date()) -> Int? {
        next.flatMap { FocusSchedule.minutes(until: $0.start, from: now, slack: 0) }
    }

    /// The length of a session started now with "Until next meeting" chosen, or
    /// nil when it is not, or no meeting is at least a minute away (the
    /// popover's own length is used). Worked out now, from the calendar as it
    /// is, never from what the menu showed. The choice is spent either way.
    func minutesToChosenMeeting(now: Date = Date()) -> Int? {
        guard isChosen else { return nil }
        isChosen = false
        refresh(now: now)
        return offeredMinutes(now: now)
    }
}

extension NidusModel {
    /// The next timed event today you have not declined, as of the last
    /// `refreshNextMeeting()`. nil without Calendar access.
    var nextMeeting: Meeting? { meetings.next }

    var calendarAccess: CalendarAccess { meetings.access }

    /// "Until next meeting" is the popover's length, and there is a meeting.
    var endsAtNextMeeting: Bool { meetings.isChosen && meetings.offeredMinutes() != nil }

    /// Looks the next meeting up. Call it when the popover opens; nothing else
    /// does, so Calendar is read only when someone is about to use it.
    func refreshNextMeeting() { meetings.refresh() }

    /// The click on "Until next meeting": the first time, macOS asks for
    /// Calendar access; after that it picks the length.
    func chooseNextMeeting() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if meetings.access == .notDetermined {
                // The prompt comes from macOS, over whatever is in front.
                NSApp.activate()
                guard await meetings.requestAccess() else { return }
            }
            meetings.refresh()
            // One end time at a time: the meeting replaces a typed "until".
            untilTarget = nil
            meetings.isChosen = meetings.offeredMinutes() != nil
            objectWillChange.send()
        }
    }
}

// MARK: - The menu item

/// The popover's length menu item. Put it last in the menu, under the fixed
/// lengths: it draws its own divider, and nothing at all when there is
/// nothing to offer.
///
/// - Calendar never asked: "Until next meeting…", which asks.
/// - Access, and a meeting at least a minute away today:
///   "Until 2:00 PM (Design review)", checked when it is the length.
/// - Access, and no meeting left today, or access refused: nothing.
struct UntilNextMeetingMenuItem: View {
    @ObservedObject var model: NidusModel

    var body: some View {
        switch model.calendarAccess {
        case .notDetermined:
            Divider()
            Button("Until next meeting…") { model.chooseNextMeeting() }
        case .authorized:
            if model.meetings.offeredMinutes() != nil, let meeting = model.nextMeeting {
                Divider()
                Toggle(meeting.menuTitle, isOn: Binding(
                    get: { model.endsAtNextMeeting },
                    set: { if $0 { model.chooseNextMeeting() } }
                ))
            }
        case .unavailable:
            EmptyView()
        }
    }
}
