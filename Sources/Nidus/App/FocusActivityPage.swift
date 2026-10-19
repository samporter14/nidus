//
//  FocusActivityPage.swift
//  Nidus
//
//  A session-scoped view of the apps, sites, and (when enabled) document
//  titles that were in front during focus. It reports observed time, not a
//  measure of productivity.
//

import AppKit
import SwiftUI

struct FocusActivityPage: View {
    @ObservedObject var model: NidusModel
    var now: Date? = nil
    var calendar: Calendar = .current
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var initialSessionID: UUID? = nil

    init(model: NidusModel, now: Date? = nil, calendar: Calendar = .current,
         initialSessionID: UUID? = nil, initialPeriod: ActivityPeriod = .week) {
        self.model = model
        self.now = now
        self.calendar = calendar
        self.initialSessionID = initialSessionID
        _period = State(initialValue: initialPeriod)
    }

    @State private var period: ActivityPeriod = .week
    @State private var projectID: UUID?
    @State private var selectedSession: SessionEntry?
    @State private var expandedApps = false
    @State private var expandedSites = false
    @State private var expandedDocuments = false
    @State private var expandedSessions = false
    @State private var selectedDay: Date?
    @State private var periodOffset = 0
    @State private var displayedSessions: [SessionEntry] = []
    @State private var displayedTotals = ActivityTotals(sessions: [])
    @State private var displayedCacheKey: ActivityCacheKey?
    @State private var displayedProjects: [ActivityProjectChoice] = []
    @State private var displayedProjectsVersion = -1

    private var sessions: [SessionEntry] { model.activitySessions }
    private var effectiveNow: Date { now ?? model.controller?.now ?? Date() }
    private var requestedCacheKey: ActivityCacheKey {
        let interval = period.interval(around: period.anchor(offset: periodOffset, from: effectiveNow, calendar: calendar), calendar: calendar)
        return ActivityCacheKey(version: model.controller?.historyVersion ?? 0,
                                start: interval.start, end: interval.end, projectID: projectID)
    }
    var body: some View {
        let rangeSessions = displayedSessions
        let summary = displayedTotals
        return NidusSettingsPage {
            hero(summary)
            filters
            if rangeSessions.isEmpty {
                emptyState
            } else {
                overview(summary, sessions: rangeSessions)
                dailyPattern(summary, sessions: rangeSessions)
                projectInsights
                rankings(title: "Apps", subtitle: "Apps observed in front", rows: summary.apps,
                         expanded: $expandedApps, tint: ActivityInk.blue)
                if !summary.sites.isEmpty {
                    rankings(title: "Recognized sites", subtitle: "Sites identified in supported browsers", rows: summary.sites,
                             expanded: $expandedSites, tint: ActivityInk.sage)
                }
                if !summary.documents.isEmpty {
                    rankings(title: "Titles", subtitle: "Document and conversation names, when enabled", rows: summary.documents,
                             expanded: $expandedDocuments, tint: ActivityInk.clay)
                }
                sessionList(rangeSessions)
            }
            NidusSettingsCard { ActivityTrackingControls(model: model) }
            coverageNote
        }
        .sheet(item: $selectedSession) { entry in
            ActivitySessionRecap(entry: entry)
                .frame(minWidth: 430, minHeight: 440)
        }
        .onAppear { refreshCache(); openInitialSession() }
        .onChange(of: requestedCacheKey) { _, _ in refreshCache() }
    }

    private func hero(_ totals: ActivityTotals) -> some View {
        NidusSettingsSection {
            VStack(alignment: .leading, spacing: 5) {
                Text("Activity")
                    .font(.system(size: 28, weight: .regular, design: .serif))
                    .foregroundStyle(.primary)
                Text("A record of what was in front during focus sessions.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                if let lead = totals.lead {
                    Text("Most observed: \(lead.name) · \(ActivityDuration.string(lead.seconds))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ActivityInk.clay)
                        .padding(.top, 4)
                        .accessibilityLabel("Most observed: \(lead.name), \(ActivityDuration.string(lead.seconds))")
                }
            }
            .padding(.top, 4)
        } content: {
            EmptyView()
        }
    }

    private var filters: some View {
        NidusSettingsCard {
            HStack(spacing: 10) {
                Picker("Time range", selection: $period) {
                    ForEach(ActivityPeriod.allCases) { value in Text(value.title).tag(value) }
                }
                .onChange(of: period) { _, _ in periodOffset = 0; selectedDay = nil }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Activity time range")
                if !displayedProjects.isEmpty {
                    Picker("Project", selection: $projectID) {
                        Text("All projects").tag(UUID?.none)
                        ForEach(displayedProjects) { project in
                            Text(project.name).tag(UUID?.some(project.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 155)
                    .accessibilityLabel("Filter activity by project")
                    .onChange(of: projectID) { _, _ in selectedDay = nil }
                }
                HStack(spacing: 3) {
                    Button { periodOffset -= 1; selectedDay = nil } label: {
                        Image(systemName: "chevron.left").frame(width: 22, height: 24)
                    }
                    .accessibilityLabel("Previous \(period.title.lowercased())")
                    Button { periodOffset = min(0, periodOffset + 1); selectedDay = nil } label: {
                        Image(systemName: "chevron.right").frame(width: 22, height: 24)
                    }
                    .disabled(periodOffset == 0)
                    .accessibilityLabel("Next \(period.title.lowercased())")
                }
                .buttonStyle(.plain)
                Text(periodLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 96)
            }
            .padding(.vertical, 4)
        }
    }

    private var emptyState: some View {
        NidusSettingsCard {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.stack.badge.clock")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(ActivityInk.clay)
                Text("No activity in this view")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                Text("Activity appears here for recorded focus sessions in the selected time range and project.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
        }
    }

    private func overview(_ totals: ActivityTotals, sessions: [SessionEntry]) -> some View {
        NidusSettingsCard {
            HStack(alignment: .center, spacing: 0) {
                ActivityFigure(label: "Focused", value: ActivityDuration.string(totals.focused), color: ActivityInk.clay)
                Divider().frame(height: 42)
                ActivityFigure(label: "Observed", value: ActivityDuration.string(totals.observed), color: ActivityInk.blue)
                Divider().frame(height: 42)
                ActivityFigure(label: "Unobserved", value: ActivityDuration.string(max(0, totals.focused - totals.observed)), color: ActivityInk.sage)
                Divider().frame(height: 42)
                ActivityFigure(label: "Sessions", value: "\(sessions.count)", color: ActivityInk.blue)
            }
            .padding(.vertical, 8)
        }
    }

    private func dailyPattern(_ totals: ActivityTotals, sessions: [SessionEntry]) -> some View {
        NidusSettingsSection {
            VStack(alignment: .leading, spacing: 3) {
                settingsSectionHeader("Daily pattern")
                Text("Observed time by the app or recognized site in front, grouped by session start day.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } content: {
            NidusSettingsCard {
                ActivityDailyChart(buckets: totals.chartBuckets, period: period,
                                   anchor: period.anchor(offset: periodOffset, from: effectiveNow, calendar: calendar),
                                   calendar: calendar, series: totals.services, selectedDay: $selectedDay)
                    .frame(height: period == .today ? 106 : 144)
                    .padding(.top, 6)
                HStack(spacing: 14) {
                    ForEach(Array(totals.services.enumerated()), id: \.element.id) { index, item in
                        ActivityLegend(color: ActivityInk.series(index), title: item.name)
                    }
                }
                .font(.system(size: 10))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 3)
            }
        }
    }

    private var projectInsights: some View {
        let values = projectInsightValues
        guard !values.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(NidusSettingsSection {
            VStack(alignment: .leading, spacing: 3) {
                settingsSectionHeader("Project insight")
                Text("Observed activity across projects in this time range.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } content: {
            NidusSettingsCard {
                ForEach(values.prefix(4)) { item in
                    Button {
                        projectID = item.projectID
                        selectedDay = nil
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(item.lead.map { "Most observed: \($0.name)" } ?? "No observed activity")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(ActivityDuration.string(item.observed))
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(ActivityInk.blue)
                                    .monospacedDigit()
                                Text("\(item.sessionCount) \(item.sessionCount == 1 ? "session" : "sessions")")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.name), \(ActivityDuration.string(item.observed)) observed across \(item.sessionCount) sessions. Filter to this project.")
                }
            }
        })
    }

    private var projectInsightValues: [ActivityProjectInsight] {
        let anchor = period.anchor(offset: periodOffset, from: effectiveNow, calendar: calendar)
        let interval = period.interval(around: anchor, calendar: calendar)
        return ActivityProjectInsights.summaries(sessions: sessions, interval: interval, calendar: calendar)
    }

    private func rankings(title: String, subtitle: String, rows: [ActivityRank], expanded: Binding<Bool>, tint: Color) -> some View {
        let visible = expanded.wrappedValue ? rows : Array(rows.prefix(5))
        return NidusSettingsSection {
            VStack(alignment: .leading, spacing: 3) {
                settingsSectionHeader(title)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } content: {
            NidusSettingsCard {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, row in
                    ActivityRankRow(rank: index + 1, item: row, maximum: rows.first?.seconds ?? row.seconds, tint: tint)
                }
                if rows.count > 5 {
                    Button(expanded.wrappedValue ? "Show less" : "Show all \(rows.count)") {
                        if reduceMotion { expanded.wrappedValue.toggle() }
                        else { withAnimation(.easeInOut(duration: 0.2)) { expanded.wrappedValue.toggle() } }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ActivityInk.clay)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 3)
                    .accessibilityHint("Expands the ranked list")
                }
            }
        }
    }

    private func sessionList(_ scoped: [SessionEntry]) -> some View {
        let rows = selectedDay.map { day in scoped.filter { calendar.isDate($0.start, inSameDayAs: day) } } ?? scoped
        return NidusSettingsSection {
            VStack(alignment: .leading, spacing: 3) {
                settingsSectionHeader("Session recaps")
                Text("Open a session to see its observed activity.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } content: {
            NidusSettingsCard {
                if let selectedDay {
                    HStack {
                        Text("Sessions on \(selectedDay.formatted(date: .abbreviated, time: .omitted))")
                        Spacer()
                        Button("Clear") { self.selectedDay = nil }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                ForEach(Array(rows.prefix(expandedSessions ? rows.count : 12))) { entry in
                    Button { selectedSession = entry } label: {
                        ActivitySessionRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityHint("Opens the session recap")
                }
                if rows.count > 12 {
                    Button(expandedSessions ? "Show fewer sessions" : "Show all \(rows.count) sessions") {
                        if reduceMotion { expandedSessions.toggle() }
                        else { withAnimation(.easeInOut(duration: 0.2)) { expandedSessions.toggle() } }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ActivityInk.clay)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private var coverageNote: some View {
        NidusSettingsCard {
            VStack(alignment: .leading, spacing: 5) {
                Label("Coverage varies by session", systemImage: "info.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Only time observed during focus sessions is shown. Older sessions may contain app totals only. Sessions recorded with activity tracking off have no new activity measurements. Recognized sites and titles are available only when captured. Unobserved time includes focus time with no activity sample. This view describes what was in front, not how productive a session was.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 3)
        }
    }

    private func openInitialSession() {
        guard let initialSessionID, let entry = sessions.first(where: { $0.id == initialSessionID }) else { return }
        selectedSession = entry
    }

    private func refreshCache() {
        let key = requestedCacheKey
        let source = sessions
        if displayedProjectsVersion != key.version {
            var seen = Set<UUID>()
            displayedProjects = source.compactMap { entry in
                guard let id = entry.projectID, let name = entry.projectName, !name.isEmpty,
                      seen.insert(id).inserted else { return nil }
                return ActivityProjectChoice(id: id, name: name)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            displayedProjectsVersion = key.version
        }
        guard key != displayedCacheKey else { return }
        displayedSessions = source.filter { entry in
            key.start <= entry.start && entry.start < key.end
                && (key.projectID == nil || entry.projectID == key.projectID)
        }.sorted { $0.start > $1.start }
        displayedTotals = ActivityTotals(sessions: displayedSessions, calendar: calendar)
        displayedCacheKey = key
    }

    private var periodLabel: String {
        let anchor = period.anchor(offset: periodOffset, from: effectiveNow, calendar: calendar)
        switch period {
        case .today: return anchor.formatted(.dateTime.month(.abbreviated).day())
        case .week:
            let start = period.interval(around: anchor, calendar: calendar).start
            return "Week of " + start.formatted(.dateTime.month(.abbreviated).day())
        case .month: return anchor.formatted(.dateTime.month(.wide).year())
        }
    }
}

private struct ActivityCacheKey: Hashable {
    let version: Int
    let start: Date
    let end: Date
    let projectID: UUID?
}

private struct ActivityProjectChoice: Identifiable {
    let id: UUID
    let name: String
}

struct ActivityProjectInsight: Identifiable {
    let projectID: UUID
    let name: String
    let observed: TimeInterval
    let lead: ActivityRank?
    let sessionCount: Int
    var id: UUID { projectID }
}

enum ActivityProjectInsights {
    static func summaries(sessions: [SessionEntry], interval: DateInterval,
                          calendar: Calendar = .current) -> [ActivityProjectInsight] {
        let inRange = sessions.filter { interval.start <= $0.start && $0.start < interval.end }
        let attributed = inRange.compactMap { entry in entry.projectID.map { ($0, entry) } }
        let groups = Dictionary(grouping: attributed, by: { $0.0 })
        return groups.map { projectID, pairs in
            let entries = pairs.map(\.1)
            let totals = ActivityTotals(sessions: entries, calendar: calendar)
            let name = entries.compactMap(\.projectName).first(where: { !$0.isEmpty }) ?? "Project"
            return ActivityProjectInsight(projectID: projectID, name: name, observed: totals.observed,
                                          lead: totals.lead, sessionCount: entries.count)
        }.sorted {
            $0.observed == $1.observed ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : $0.observed > $1.observed
        }
    }
}

enum ActivityPeriod: String, CaseIterable, Identifiable {
    case today, week, month
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    func anchor(offset: Int, from now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch self {
        case .today: return calendar.date(byAdding: .day, value: offset, to: now) ?? now
        case .week: return calendar.date(byAdding: .weekOfYear, value: offset, to: now) ?? now
        case .month: return calendar.date(byAdding: .month, value: offset, to: now) ?? now
        }
    }

    func interval(around now: Date, calendar: Calendar = .current) -> DateInterval {
        switch self {
        case .today:
            return calendar.dateInterval(of: .day, for: now) ?? DateInterval(start: calendar.startOfDay(for: now), duration: 86_400)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: now) ?? DateInterval(start: calendar.startOfDay(for: now).addingTimeInterval(-6 * 86_400), duration: 7 * 86_400)
        case .month:
            return calendar.dateInterval(of: .month, for: now) ?? DateInterval(start: calendar.startOfDay(for: now), duration: 31 * 86_400)
        }
    }

    func contains(_ date: Date, offset: Int = 0, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let interval = interval(around: anchor(offset: offset, from: now, calendar: calendar), calendar: calendar)
        return interval.start <= date && date < interval.end
    }
}

/// Activity values retain second-level precision for short observations.
enum ActivityDuration {
    static func string(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        guard totalSeconds < 60 else { return FocusFormat.long(TimeInterval(totalSeconds)) }
        return "\(totalSeconds) \(totalSeconds == 1 ? "sec" : "sec")"
    }
}

private enum ActivityInk {
    static let clay = FocusPalette.clay
    static let blue = Color(light: Color(.sRGB, red: 0.36, green: 0.55, blue: 0.70, opacity: 1), dark: Color(.sRGB, red: 0.53, green: 0.69, blue: 0.81, opacity: 1))
    static let sage = Color(light: Color(.sRGB, red: 0.48, green: 0.62, blue: 0.52, opacity: 1), dark: Color(.sRGB, red: 0.63, green: 0.76, blue: 0.65, opacity: 1))
    static func series(_ index: Int) -> Color {
        switch index % 5 {
        case 0: return blue
        case 1: return sage
        case 2: return clay
        case 3: return Color(light: Color(.sRGB, red: 0.68, green: 0.57, blue: 0.42, opacity: 1), dark: Color(.sRGB, red: 0.82, green: 0.71, blue: 0.54, opacity: 1))
        default: return Color(light: Color(.sRGB, red: 0.57, green: 0.54, blue: 0.67, opacity: 1), dark: Color(.sRGB, red: 0.72, green: 0.68, blue: 0.82, opacity: 1))
        }
    }
}

private extension Color {
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }
}

struct ActivityTotals {
    var focused: TimeInterval = 0
    var observed: TimeInterval = 0
    var apps: [ActivityRank] = []
    var sites: [ActivityRank] = []
    var documents: [ActivityRank] = []
    var services: [ActivityRank] = []
    var chartBuckets: [Date: [String: TimeInterval]] = [:]

    var lead: ActivityRank? { services.first }
    init(sessions: [SessionEntry], calendar: Calendar = .current) {
        var appSeconds: [String: TimeInterval] = [:]
        var siteSeconds: [String: TimeInterval] = [:]
        var documentSeconds: [String: TimeInterval] = [:]
        var documentTitles: [String: String] = [:]
        var documentSources: [String: String] = [:]
        var appNames: [String: String] = [:]
        var serviceSeconds: [String: TimeInterval] = [:]
        var serviceSecondsByDay: [Date: [String: TimeInterval]] = [:]
        for session in sessions {
            focused += max(0, session.focused)
            let day = calendar.startOfDay(for: session.start)
            if let activity = session.activity {
                for item in activity where item.seconds > 0 {
                    observed += item.seconds
                    appNames[item.appID] = item.appName
                    appSeconds[item.appID, default: 0] += item.seconds
                    let service = item.site?.isEmpty == false ? item.site! : item.appName
                    serviceSeconds[service, default: 0] += item.seconds
                    serviceSecondsByDay[day, default: [:]][service, default: 0] += item.seconds
                    if let site = item.site, !site.isEmpty { siteSeconds[site, default: 0] += item.seconds }
                    if let title = item.title, !title.isEmpty {
                        let key = "\(item.appID)\u{1F}\(item.site ?? "")\u{1F}\(title)"
                        let source = [item.appName, item.site].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                        documentSeconds[key, default: 0] += item.seconds
                        documentTitles[key] = title
                        documentSources[key] = source
                    }
                }
            } else {
                // Legacy records have an app-only foreground map. Keep that
                // coverage visible without implying websites or titles exist.
                for (appID, seconds) in session.foreground where seconds > 0 {
                    observed += seconds
                    appSeconds[appID, default: 0] += seconds
                    let name = session.names[appID] ?? appID
                    appNames[appID] = name
                    serviceSeconds[name, default: 0] += seconds
                    serviceSecondsByDay[day, default: [:]][name, default: 0] += seconds
                }
            }
        }
        apps = Self.ranked(appSeconds, names: appNames)
        sites = Self.ranked(siteSeconds)
        documents = documentSeconds.map { key, seconds in
            ActivityRank(id: key, name: documentTitles[key] ?? key, seconds: seconds, subtitle: documentSources[key])
        }.sorted { $0.seconds > $1.seconds }
        let rankedServices = Self.ranked(serviceSeconds)
        if rankedServices.count > 4 {
            let top = Array(rankedServices.prefix(4))
            let remainder = rankedServices.dropFirst(4).reduce(0) { $0 + $1.seconds }
            services = top + [ActivityRank(id: "__other__", name: "Other", seconds: remainder)]
        } else {
            services = rankedServices
        }
        let chartLabels = Set(services.filter { $0.id != "__other__" }.map(\.id))
        chartBuckets = serviceSecondsByDay.mapValues { values in
            values.reduce(into: [:]) { result, pair in
                let key = chartLabels.contains(pair.key) ? pair.key : (services.count > 4 ? "__other__" : pair.key)
                result[key, default: 0] += pair.value
            }
        }
    }

    private static func ranked(_ values: [String: TimeInterval], names: [String: String] = [:]) -> [ActivityRank] {
        values.map { key, seconds in ActivityRank(id: key, name: names[key] ?? key, seconds: seconds) }
            .sorted { $0.seconds == $1.seconds ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : $0.seconds > $1.seconds }
    }
}

struct ActivityRank: Identifiable {
    var id: String
    var name: String
    var seconds: TimeInterval
    var subtitle: String? = nil
}

private struct ActivityDay: Identifiable {
    let date: Date
    var values: [String: TimeInterval] = [:]
    var total: TimeInterval { values.values.reduce(0, +) }
    var id: Date { date }
}

private struct ActivityFigure: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(size: 28, weight: .regular, design: .serif))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }
}

private struct ActivityDailyChart: View {
    let buckets: [Date: [String: TimeInterval]]
    let period: ActivityPeriod
    let anchor: Date
    let calendar: Calendar
    let series: [ActivityRank]
    @Binding var selectedDay: Date?

    private var days: [ActivityDay] {
        let interval = period.interval(around: anchor, calendar: calendar)
        let count = period == .today ? 1 : (period == .week ? 7 : (calendar.range(of: .day, in: .month, for: anchor)?.count ?? 30))
        let first = calendar.startOfDay(for: interval.start)
        var result = (0..<count).compactMap { index -> ActivityDay? in
            guard let date = calendar.date(byAdding: .day, value: index, to: first) else { return nil }
            return ActivityDay(date: date)
        }
        for index in result.indices {
            result[index].values = buckets[result[index].date] ?? [:]
        }
        return result
    }

    private var ceiling: TimeInterval { max(1, days.map(\.total).max() ?? 1) }

    var body: some View {
        VStack(spacing: 7) {
            HStack(alignment: .bottom, spacing: period == .month ? 2 : 6) {
                ForEach(days) { day in
                    Button { selectedDay = day.date } label: {
                        VStack(spacing: 4) {
                            GeometryReader { proxy in
                                let available = max(8, proxy.size.height)
                                VStack(spacing: 1) {
                                    ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                                        bar(day.values[item.id == "__other__" ? "__other__" : item.name, default: 0], height: available, color: ActivityInk.series(index))
                                    }
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            }
                            .frame(height: 85)
                            Text(axisLabel(day.date))
                                .font(.system(size: period == .month ? 8 : 9, weight: .medium))
                                .foregroundStyle(selectedDay.map { calendar.isDate($0, inSameDayAs: day.date) } == true ? ActivityInk.clay : Color.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel(day))
                    .accessibilityAddTraits(selectedDay.map { calendar.isDate($0, inSameDayAs: day.date) } == true ? .isSelected : [])
                }
            }
            HStack {
                Text("Daily scale")
                Spacer()
                Text("Up to " + ActivityDuration.string(ceiling))
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Daily observed activity chart")
    }

    private func bar(_ seconds: TimeInterval, height: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(seconds > 0 ? color.opacity(0.88) : Color.clear)
            .frame(height: seconds > 0 ? max(2, height * CGFloat(seconds / ceiling)) : 0)
    }

    private func axisLabel(_ date: Date) -> String {
        switch period {
        case .today: return "Today"
        case .week: return date.formatted(.dateTime.weekday(.narrow))
        case .month:
            let day = calendar.component(.day, from: date)
            return day == 1 || day == days.count ? "\(day)" : (day.isMultiple(of: 5) ? "\(day)" : "")
        }
    }

    private func accessibilityLabel(_ day: ActivityDay) -> String {
        let date = day.date.formatted(date: .complete, time: .omitted)
        let detail = series.compactMap { item -> String? in
            guard let value = day.values[item.id == "__other__" ? "__other__" : item.name], value > 0 else { return nil }
            return "\(item.name), \(ActivityDuration.string(value))"
        }.joined(separator: "; ")
        return "\(date), \(ActivityDuration.string(day.total)) observed. \(detail). Activate to filter sessions for this day."
    }
}

private struct ActivityLegend: View {
    let color: Color
    let title: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ActivityRankRow: View {
    let rank: Int
    let item: ActivityRank
    let maximum: TimeInterval
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Text(String(format: "%02d", rank))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, alignment: .leading)
                Text(verbatim: item.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(ActivityDuration.string(item.seconds))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.leading, 31)
            }
            GeometryReader { proxy in
                Capsule().fill(Color.primary.opacity(0.055))
                    .overlay(alignment: .leading) {
                        Capsule().fill(tint.opacity(0.85))
                            .frame(width: Swift.max(4, proxy.size.width * min(1, item.seconds / maximum)))
                    }
            }
            .frame(height: 4)
            .padding(.leading, 31)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Rank \(rank), \(item.name), \(ActivityDuration.string(item.seconds))")
    }
}

private struct ActivitySessionRow: View {
    let entry: SessionEntry
    private var hasDetails: Bool { entry.activity != nil }
    private var observed: TimeInterval {
        if let activity = entry.activity { return activity.reduce(0) { $0 + max(0, $1.seconds) } }
        return entry.foreground.values.filter { $0 > 0 }.reduce(0, +)
    }

    var body: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 2).fill(hasDetails ? ActivityInk.clay : ActivityInk.blue)
                .frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(entry.start.formatted(.dateTime.hour().minute()))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if !hasDetails {
                        Text("APP ONLY")
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .tracking(0.4)
                            .foregroundStyle(ActivityInk.blue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(ActivityInk.blue.opacity(0.12), in: Capsule())
                    }
                }
                Text(entry.goal.isEmpty ? (entry.projectName ?? "Focus session") : entry.goal)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(ActivityDuration.string(entry.focused))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("\(ActivityDuration.string(observed)) observed")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 3)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.goal.isEmpty ? (entry.projectName ?? "Focus session") : entry.goal), \(entry.start.formatted(date: .abbreviated, time: .shortened)), focused for \(ActivityDuration.string(entry.focused)), \(ActivityDuration.string(observed)) observed, \(hasDetails ? "detailed activity available" : "app only coverage")")
    }
}

struct ActivitySessionRecap: View {
    let entry: SessionEntry
    @Environment(\.dismiss) private var dismiss

    private var items: [FocusActivity] { entry.activity ?? [] }
    private var legacyApps: [ActivityRank] {
        entry.foreground.map { key, seconds in
            ActivityRank(id: key, name: entry.names[key] ?? key, seconds: seconds)
        }.filter { $0.seconds > 0 }.sorted { $0.seconds > $1.seconds }
    }
    private var observed: TimeInterval {
        if entry.activity != nil { return items.reduce(0) { $0 + max(0, $1.seconds) } }
        return legacyApps.reduce(0) { $0 + $1.seconds }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.goal.isEmpty ? (entry.projectName ?? "Focus session") : entry.goal)
                            .font(.system(size: 28, weight: .regular, design: .serif))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(entry.start.formatted(.dateTime.weekday(.wide).month(.wide).day()) + " · " + entry.start.formatted(.dateTime.hour().minute()))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 0) {
                        ActivityFigure(label: "Focused", value: ActivityDuration.string(entry.focused), color: ActivityInk.clay)
                        Divider().frame(height: 40)
                        ActivityFigure(label: "Observed", value: ActivityDuration.string(observed), color: ActivityInk.blue)
                    }
                    .padding(.vertical, 8)
                    composition
                    ActivitySessionTimeline(entry: entry)
                    if let activity = entry.activity {
                        recapActivity(activity)
                    } else {
                        legacyRecap
                    }
                    if !entry.goal.isEmpty {
                        Label(entry.finished.map { $0 ? "Goal finished" : "Goal not finished" } ?? "Goal answer not recorded", systemImage: entry.finished == true ? "checkmark.circle" : "circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var composition: some View {
        let services = ActivityTotals(sessions: [entry]).services
        let total = services.reduce(0) { $0 + $1.seconds }
        return VStack(alignment: .leading, spacing: 9) {
            if total > 0 {
                Text("Where this session went")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                GeometryReader { proxy in
                    HStack(spacing: 3) {
                        ForEach(Array(services.enumerated()), id: \.element.id) { index, service in
                            RoundedRectangle(cornerRadius: 5)
                                .fill(ActivityInk.series(index))
                                .frame(width: max(0, proxy.size.width - CGFloat(services.count - 1) * 3) * service.seconds / total)
                                .help("\(service.name): \(ActivityDuration.string(service.seconds))")
                        }
                    }
                }
                .frame(height: 22)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(services.map { "\($0.name), \(ActivityDuration.string($0.seconds))" }.joined(separator: "; "))
            }
        }
    }

    @ViewBuilder private func recapActivity(_ activity: [FocusActivity]) -> some View {
        let apps = aggregate(activity, by: \.appName)
        let sites = aggregate(activity.compactMap { item in
            guard let site = item.site, !site.isEmpty else { return nil }
            return (site, item.seconds)
        })
        let documents = aggregateDocuments(activity)
        VStack(alignment: .leading, spacing: 12) {
            recapGroup("Apps", rows: apps)
            if !sites.isEmpty { recapGroup("Recognized sites", rows: sites) }
            if !documents.isEmpty { recapGroup("Titles", rows: documents) }
            if activity.isEmpty {
                Text("No activity details were observed during this session.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var legacyRecap: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("App-only coverage", systemImage: "info.circle")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(ActivityInk.blue)
            Text("Detailed activity was not recorded for this session. Any available app totals are shown below.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            recapGroup("Apps observed", rows: legacyApps)
        }
    }

    private func recapGroup(_ title: String, rows: [ActivityRank]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("No time recorded").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                ForEach(rows.prefix(12)) { row in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: row.name).lineLimit(1).truncationMode(.middle)
                            if let subtitle = row.subtitle, !subtitle.isEmpty {
                                Text(verbatim: subtitle).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(ActivityDuration.string(row.seconds)).monospacedDigit()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func aggregate(_ values: [(String, TimeInterval)]) -> [ActivityRank] {
        var totals: [String: TimeInterval] = [:]
        values.forEach { totals[$0.0, default: 0] += max(0, $0.1) }
        return totals.map { ActivityRank(id: $0.key, name: $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }
    }

    private func aggregate(_ activity: [FocusActivity], by keyPath: KeyPath<FocusActivity, String>) -> [ActivityRank] {
        aggregate(activity.map { ($0[keyPath: keyPath], $0.seconds) })
    }

    private func aggregateDocuments(_ activity: [FocusActivity]) -> [ActivityRank] {
        var secondsByKey: [String: TimeInterval] = [:]
        var titles: [String: String] = [:]
        var sources: [String: String] = [:]
        for item in activity {
            guard let title = item.title, !title.isEmpty else { continue }
            let key = "\(item.appID)\u{1F}\(item.site ?? "")\u{1F}\(title)"
            secondsByKey[key, default: 0] += max(0, item.seconds)
            titles[key] = title
            sources[key] = [item.appName, item.site].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return secondsByKey.map { key, seconds in
            ActivityRank(id: key, name: titles[key] ?? key, seconds: seconds, subtitle: sources[key])
        }.sorted { $0.seconds > $1.seconds }
    }
}

private struct ActivitySessionTimeline: View {
    let entry: SessionEntry
    @State private var expanded = false

    private var segments: [FocusActivitySegment] {
        (entry.activitySegments ?? []).sorted { $0.start < $1.start }
    }

    private var blocks: [ActivityTimelineBlock] {
        var result: [ActivityTimelineBlock] = []
        for segment in segments {
            if let last = result.last,
               ActivityTimeline.sameContext(last.lastSegment, segment),
               ActivityTimeline.touches(last.lastSegment, segment) {
                result[result.count - 1].append(segment)
            } else {
                result.append(ActivityTimelineBlock(segment))
            }
        }
        return result
    }

    private var documentSwitches: Int {
        zip(segments, segments.dropFirst()).reduce(0) { count, pair in
            let previous = pair.0, current = pair.1
            let changed = previous.appID == current.appID && previous.site == current.site
                && previous.title != nil && current.title != nil && previous.title != current.title
            return count + (changed && ActivityTimeline.touches(previous, current) ? 1 : 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Observed timeline")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if let segments = entry.activitySegments {
                HStack(spacing: 0) {
                    ActivityTimelineMetric(label: "Context switches", value: "\(entry.activitySwitchCount ?? 0)", color: ActivityInk.clay)
                    Divider().frame(height: 34)
                    ActivityTimelineMetric(label: "Document switches", value: "\(documentSwitches)", color: ActivityInk.clay)
                    Divider().frame(height: 34)
                    ActivityTimelineMetric(label: entry.activityTimelineTruncated == true ? "Longest retained context stretch" : "Longest same-context stretch",
                                           value: ActivityDuration.string(entry.longestObservedStretch ?? 0), color: ActivityInk.blue)
                }
                .padding(.vertical, 4)
                if entry.activityTimelineTruncated == true {
                    Label("Earlier observations were omitted; metrics describe the retained timeline.", systemImage: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if segments.isEmpty {
                    Text("No activity intervals were observed during this session.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    let visible = expanded ? blocks : Array(blocks.prefix(12))
                    VStack(spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, block in
                            if index > 0, block.start > visible[index - 1].end {
                                ActivityTimelineGap(start: visible[index - 1].end, end: block.start)
                            }
                            ActivityTimelineRow(block: block, isLast: index == visible.count - 1)
                        }
                    }
                    if blocks.count > 12 {
                        Button(expanded ? "Show fewer intervals" : "Show all \(blocks.count) intervals") {
                            expanded.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ActivityInk.clay)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            } else {
                Label("Timeline unavailable for this older session", systemImage: "clock.badge.questionmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ActivityInk.blue)
                Text("This session has app totals, but no ordered observations were saved. Context switches and uninterrupted stretches cannot be determined.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ActivityTimelineMetric: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: value)
                .font(.system(size: 15, weight: .regular, design: .serif))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .accessibilityElement(children: .combine)
    }
}

private struct ActivityTimelineBlock: Identifiable {
    private(set) var values: [FocusActivitySegment]
    var id: String { values.first?.id ?? UUID().uuidString }
    var firstSegment: FocusActivitySegment { values[0] }
    var lastSegment: FocusActivitySegment { values[values.count - 1] }
    var start: Date { firstSegment.start }
    var end: Date { lastSegment.end }
    var seconds: TimeInterval { values.reduce(0) { $0 + $1.seconds } }
    var appName: String { firstSegment.appName }
    var contextName: String { firstSegment.site ?? firstSegment.title ?? firstSegment.appName }
    var detail: String? {
        guard let title = firstSegment.title, title != contextName else { return nil }
        return title
    }

    init(_ segment: FocusActivitySegment) { values = [segment] }
    mutating func append(_ segment: FocusActivitySegment) { values.append(segment) }
}

private struct ActivityTimelineRow: View {
    let block: ActivityTimelineBlock
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle().fill(ActivityInk.blue).frame(width: 7, height: 7)
                Rectangle().fill(ActivityInk.blue.opacity(0.2)).frame(width: 1).frame(minHeight: 30)
                    .opacity(isLast ? 0 : 1)
            }
            .frame(width: 8)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(block.start.formatted(.dateTime.hour().minute()) + "–" + block.end.formatted(.dateTime.hour().minute()))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    Text(ActivityDuration.string(block.seconds))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(ActivityInk.blue)
                        .monospacedDigit()
                }
                Text(block.contextName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let detail = block.detail {
                    Text(detail).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                } else if block.firstSegment.site != nil {
                    Text(block.appName).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.bottom, 9)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(block.start.formatted(date: .omitted, time: .shortened)) to \(block.end.formatted(date: .omitted, time: .shortened)), \(block.contextName), \(ActivityDuration.string(block.seconds))")
    }
}

private struct ActivityTimelineGap: View {
    let start: Date
    let end: Date

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "minus")
            Text("No observation · \(ActivityDuration.string(end.timeIntervalSince(start))) · \(start.formatted(.dateTime.hour().minute()))–\(end.formatted(.dateTime.hour().minute()))")
            Spacer(minLength: 0)
        }
        .font(.system(size: 8, weight: .medium))
        .foregroundStyle(.tertiary)
        .padding(.leading, 18)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}
