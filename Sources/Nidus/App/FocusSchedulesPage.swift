//
//  FocusSchedulesPage.swift
//  Nidus
//
//  Settings, Schedules: the tab with the list of weekly schedules, each with
//  its own switch, and a page per schedule for its days, times, categories
//  and goal. The rules for when they run are in Core/FocusSchedule.swift; the
//  scheduler that acts on them is FocusScheduler.
//

import SwiftUI

extension NidusModel {
    /// "schedules", or "schedule:<id>" for one schedule's page.
    func makeSchedulesPage(id: String) -> AnyView? {
        if id == "schedules" { return AnyView(FocusSchedulesPage(model: self)) }
        guard id.hasPrefix(Self.schedulePagePrefix) else { return nil }
        let scheduleID = String(id.dropFirst(Self.schedulePagePrefix.count))
        guard schedules.contains(where: { $0.id == scheduleID }) else { return nil }
        return AnyView(FocusSchedulePage(model: self, scheduleID: scheduleID))
    }
}

// MARK: - The list

struct FocusSchedulesPage: View {
    @ObservedObject var model: NidusModel
    private let calendar = Calendar.autoupdatingCurrent

    var body: some View {
        DropletSettingsPage {
            Section {
                if model.schedules.isEmpty {
                    Text("No schedules yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.schedules) { schedule in
                    FocusScheduleRow(model: model, schedule: schedule, calendar: calendar)
                }
                DropletControlRow(title: "New schedule") {
                    Button("Add", action: model.addSchedule)
                        .buttonStyle(.bordered)
                }
            } header: {
                // The tab is already called Schedules.
                Text("Start a session by itself, on the days and times you pick. A card shows a minute before, with Skip.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Schedules only run while Nidus is running and your Mac is awake. If it wakes or opens inside a window, a session starts then, unless less than 5 minutes are left. A schedule that starts during a session or a break is skipped.")
            }
        }
    }
}

/// One schedule in the list: open it, or switch it on and off.
struct FocusScheduleRow: View {
    @ObservedObject var model: NidusModel
    let schedule: FocusSchedule
    let calendar: Calendar
    @Environment(SettingsRouter.self) private var router

    private var title: String {
        let goal = schedule.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        return goal.isEmpty ? "Focus session" : goal
    }

    private var summary: String {
        schedule.summary(categories: model.categories, calendar: calendar)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                router.open(NidusModel.schedulePagePrefix + schedule.id, title: "Schedule")
            } label: {
                HStack(spacing: 10) {
                    CategoryTile(symbol: schedule.strict ? "lock.fill" : "calendar.badge.clock")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: title)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(verbatim: summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .opacity(schedule.isOn ? 1 : 0.55)
                    Spacer(minLength: 8)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(summary)")
            .accessibilityHint("Opens this schedule")

            Toggle("On", isOn: Binding(
                get: { schedule.isOn },
                set: { on in model.updateSchedule(schedule.id) { $0.isOn = on } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel(title)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - One schedule

struct FocusSchedulePage: View {
    @ObservedObject var model: NidusModel
    let scheduleID: String
    private let calendar = Calendar.autoupdatingCurrent

    private var schedule: FocusSchedule? {
        model.schedules.first { $0.id == scheduleID }
    }

    var body: some View {
        DropletSettingsPage {
            if let schedule {
                DropletSettingsCard {
                    DropletToggleRow(title: "On",
                                     subtitle: "Starts a session on its own at the time below.",
                                     isOn: binding(\.isOn))
                }

                DropletSettingsSection {
                    settingsSectionHeader("When")
                } content: {
                    DropletSettingsCard {
                        DropletStackedRow(title: "Days") {
                            FocusDayToggles(selection: binding(\.weekdays), calendar: calendar)
                        }
                        DropletControlRow(title: "Starts") {
                            timePicker("Starts", for: \.start) { $0.setStart($1) }
                        }
                        DropletControlRow(title: "Ends") {
                            timePicker("Ends", for: \.end) { $0.setEnd($1) }
                        }
                    }
                }

                DropletSettingsSection {
                    VStack(alignment: .leading, spacing: 2) {
                        settingsSectionHeader("What to block")
                        Text(schedule.mode == .block
                             ? "Pick the categories to block."
                             : "Pick the categories to allow. Everything else is blocked.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } content: {
                    DropletSettingsCard {
                        DropletGroupedPickerRow(title: "Mode") {
                            Picker("Mode", selection: binding(\.mode)) {
                                Text("Block list").tag(SessionPlan.Mode.block)
                                Text("Allow list").tag(SessionPlan.Mode.allow)
                            }
                            .pickerStyle(.segmented)
                        }
                        ForEach(model.categories) { category in
                            Toggle(isOn: categoryBinding(category.id)) {
                                HStack(spacing: DroppySpacing.sm) {
                                    // One width, so the names line up.
                                    Image(systemName: category.symbol)
                                        .frame(width: 22)
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                    Text(category.name)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }

                DropletSettingsCard {
                    DropletControlRow(title: "Goal") {
                        TextField("Goal", text: binding(\.goal), prompt: Text("Optional"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .labelsHidden()
                    }
                    DropletToggleRow(title: "Strict mode",
                                     subtitle: "No snooze or pause during the session, and ending one early means typing \u{201C}stop early\u{201D} in the popover.",
                                     isOn: binding(\.strict))
                }

                DropletSettingsCard {
                    DropletControlRow(title: "Delete this schedule") {
                        Button("Delete", role: .destructive) { model.deleteSchedule(scheduleID) }
                            .buttonStyle(.bordered)
                    }
                }

                Section {
                } footer: {
                    Text("Schedules only run while Nidus is running and your Mac is awake.")
                }
            }
        }
    }

    // MARK: Bindings

    private func binding<Value>(_ keyPath: WritableKeyPath<FocusSchedule, Value>) -> Binding<Value> {
        Binding(
            get: { schedule?[keyPath: keyPath] ?? FocusSchedule()[keyPath: keyPath] },
            set: { value in model.updateSchedule(scheduleID) { $0[keyPath: keyPath] = value } }
        )
    }

    private func categoryBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { schedule?.categoryIDs.contains(id) ?? false },
            set: { on in
                model.updateSchedule(scheduleID) { schedule in
                    schedule.categoryIDs.removeAll { $0 == id }
                    if on { schedule.categoryIDs.append(id) }
                }
            }
        )
    }

    /// A time of day. The picker holds a date, so the time is read and set on
    /// a day with no clock change in it.
    private func timePicker(_ title: String, for keyPath: KeyPath<FocusSchedule, ScheduleTime>,
                            set: @escaping (inout FocusSchedule, ScheduleTime) -> Void) -> some View {
        let day = ScheduleTime.referenceDay(calendar: calendar)
        return DatePicker(
            title,
            selection: Binding(
                get: { (schedule?[keyPath: keyPath] ?? ScheduleTime(hour: 9)).date(on: day, calendar: calendar) },
                set: { date in
                    model.updateSchedule(scheduleID) { set(&$0, ScheduleTime(date, calendar: calendar)) }
                }
            ),
            displayedComponents: .hourAndMinute
        )
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: - Days

/// Seven round toggles, S M T W T F S from the week's first day, as
/// Calendar's own repeat picker. Each is named in full for VoiceOver.
struct FocusDayToggles: View {
    @Binding var selection: Set<Int>
    let calendar: Calendar

    private var days: [Int] {
        (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(days, id: \.self) { weekday in
                Toggle(isOn: Binding(
                    get: { selection.contains(weekday) },
                    set: { on in
                        if on { selection.insert(weekday) } else { selection.remove(weekday) }
                    }
                )) {
                    Text(verbatim: calendar.veryShortWeekdaySymbols[weekday - 1])
                }
                .toggleStyle(DayToggleStyle())
                .accessibilityLabel(calendar.weekdaySymbols[weekday - 1])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Days")
    }
}

private struct DayToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(configuration.isOn ? Color.white : Color.primary)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(configuration.isOn ? AnyShapeStyle(FocusPalette.clay) : AnyShapeStyle(Color(nsColor: .quaternaryLabelColor)))
                )
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

// MARK: - Renders

extension RenderSurfaces {
    /// The Schedules tab with two sample schedules, one schedule's page, and
    /// the two cards. Nothing here fires: the
    /// scheduler is never started in a render, and the sample times are
    /// only drawn.
    static func renderSchedules(model: NidusModel, settings: SettingsWindowController,
                                host: NidusHost, in directory: URL) async {
        let deepWork = FocusSchedule(
            id: "sample-deep-work", weekdays: FocusSchedule.workweek,
            start: ScheduleTime(hour: 9), end: ScheduleTime(hour: 12),
            categoryIDs: ["social", "messaging"], goal: "Deep work")
        let reading = FocusSchedule(
            id: "sample-reading", weekdays: [3, 5],
            start: ScheduleTime(hour: 13, minute: 30), end: ScheduleTime(hour: 15, minute: 30),
            categoryIDs: ["mail"], mode: .allow, strict: true)
        model.schedules = [deepWork, reading]

        for (page, name) in [("schedules", "settings-schedules"), ("schedule:sample-deep-work", "settings-schedule"),
                             ("schedule:sample-reading", "settings-schedule-allow")] {
            await shootSettings(model, settings, page: page, title: page == "schedules" ? "Schedules" : "Schedule",
                                name: name, height: page == "schedules" ? 560 : 860, in: directory)
        }
        await shootWindow(settings, page: "schedules", name: "settings-window-schedules", in: directory)
        await shootWindow(settings, page: "schedule:sample-deep-work", title: "Schedule",
                          name: "settings-window-schedule", in: directory)
        settings.window?.orderOut(nil)

        let start = Date().addingTimeInterval(58)
        let run = FocusSchedule.Occurrence(schedule: deepWork, start: start, end: start.addingTimeInterval(3 * 3600))
        model.presentHeadsUp(for: run)
        if let request = host.hud.lastRequest {
            await shoot(HUDCardView(content: request.content), width: HUDPresenter.width,
                        name: "card-schedule-headsup", in: directory, padded: true)
        }
        model.presentScheduleStartedHUD(for: run)
        if let request = host.hud.lastRequest {
            await shoot(HUDCardView(content: request.content), width: HUDPresenter.width,
                        name: "card-schedule-started", in: directory, padded: true)
        }
        model.schedules = []
        await renderUntilNextMeeting(in: directory)
    }

    /// The length menu's last item in its three states, drawn as plain rows
    /// (a Menu's items do not draw off-screen). The calendar is a fake: a
    /// render never asks for access.
    private static func renderUntilNextMeeting(in directory: URL) async {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let start = min(now.addingTimeInterval(40 * 60), endOfToday.addingTimeInterval(-120))
        let meeting = CalendarEvent(title: "Design review", start: start, end: start.addingTimeInterval(3600))

        func model(_ access: CalendarAccess, _ events: [CalendarEvent]) -> NidusModel {
            let model = NidusModel()
            model.meetings.source = FakeCalendarSource(access: access, events: events)
            model.meetings.refresh(now: now)
            return model
        }
        let states: [(String, NidusModel)] = [
            ("Calendar not asked yet", model(.notDetermined, [meeting])),
            ("Calendar allowed, a meeting today", model(.authorized, [meeting])),
            ("Calendar allowed, nothing left today", model(.authorized, [])),
        ]
        let view = VStack(alignment: .leading, spacing: 14) {
            ForEach(states.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 4) {
                    Text(states[index].0).font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        UntilNextMeetingMenuItem(model: states[index].1)
                    }
                    .frame(minHeight: 22, alignment: .leading)
                }
            }
        }
        .frame(width: 320, alignment: .leading)
        .padding(16)
        await shoot(view, width: 352, name: "calendar-menu-item", in: directory)
    }
}
