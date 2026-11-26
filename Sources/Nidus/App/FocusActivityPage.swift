//
//  FocusActivityPage.swift
//  Nidus
//
//  The apps, sites, and (when enabled) document titles that were in front:
//  all day where the daily record is on, and during focus sessions always.
//  It reports observed time, not a measure of productivity.
//

import AppKit
import SwiftUI

struct FocusActivityPage: View {
    @ObservedObject var model: NidusModel
    var now: Date? = nil
    var calendar: Calendar = .current
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    var initialSessionID: UUID? = nil

    init(model: NidusModel, now: Date? = nil, calendar: Calendar = .current,
         initialSessionID: UUID? = nil, initialPeriod: ActivityPeriod = .today,
         initialListKind: ActivityListKind = .apps, initialCategoryFilter: String? = nil) {
        self.model = model
        self.now = now
        self.calendar = calendar
        self.initialSessionID = initialSessionID
        _period = State(initialValue: initialPeriod)
        _listKind = State(initialValue: initialListKind)
        _categoryFilter = State(initialValue: initialCategoryFilter)
    }

    @State private var period: ActivityPeriod = .today
    @State private var projectID: UUID?
    @State private var selectedSession: SessionEntry?
    @State private var listKind: ActivityListKind = .apps
    @State private var expandedList = false
    @State private var expandedSessions = false
    @State private var selectedDay: Date?
    @State private var periodOffset = 0
    @State private var focusOnly = false
    @State private var displayedSessions: [SessionEntry] = []
    @State private var displayedScope = ActivityScope(logs: [], sessions: [])
    @State private var displayedLoadKey: ActivityCacheKey?
    @State private var displayedProjects: [ActivityProjectChoice] = []
    /// Worked out in `reload`, not in `body`, so a redraw doesn't redo it.
    @State private var displayedInsights: [ActivityProjectInsight] = []
    @State private var displayedProjectsVersion = -1
    /// A group's id (Uncategorized's included): the ranked lists count only its time.
    @State private var categoryFilter: String?
    // Worked out in `reload`, with the scope, so a body pass reads them.
    @State private var displayedCategorizer = ActivityCategorizer(categories: [], work: FocusCategory.workSeed)
    @State private var displayedCategories: [ActivityCategoryTotal] = []
    @State private var displayedUncategorized: [ActivityUncategorizedItem] = []
    @State private var displayedFiltered: ActivityTotals?
    @State private var digestCache = ActivityDigestCache()
    @State private var displayedHeatmap = ActivityHeatmap()
    @State private var displayedWeek: ActivityWeek?
    @State private var displayedTrends: ActivityTrends?
    @State private var displayedChains: [ActivityDriftChain]?
    /// Whether the week, hour and drift digest has arrived: until it has,
    /// their cards hold their height as an empty track.
    @State private var digestLoaded = false
    /// The same weekday's earlier figures, for the comparison lines.
    @State private var comparisonHistory = ActivityComparisonHistory()
    @State private var tracker = ActivitySectionTracker()
    /// Open rows of the ranked list: app ids, and app and site together.
    @State private var openRows: Set<String> = []

    private var sessions: [SessionEntry] { model.activitySessions }
    private var effectiveNow: Date { now ?? Date() }
    private var displayedTotals: ActivityTotals { displayedScope.totals }
    private var requestedInterval: DateInterval {
        period.interval(around: period.anchor(offset: periodOffset, from: effectiveNow, calendar: calendar), calendar: calendar)
    }
    private var requestedCacheKey: ActivityCacheKey {
        let interval = requestedInterval
        return ActivityCacheKey(version: model.controller?.historyVersion ?? 0,
                                dayVersion: ActivityCacheKey.dayVersion(model.controller?.activityDayVersion ?? 0,
                                                                        start: interval.start, end: interval.end, now: effectiveNow),
                                start: interval.start, end: interval.end, projectID: projectID, focusOnly: focusOnly,
                                excluded: model.activityExcludedApps, work: model.workGroup, categories: model.categories,
                                overrides: model.activityOverrides, categoryFilter: categoryFilter,
                                includeTimeline: period == .today)
    }
    /// The session running now, for the ribbon and focus-only views.
    private var liveFocus: ActivityRibbon.Focus? {
        guard let controller = model.controller, controller.engine.isRunning, let session = controller.engine.session,
              session.startedAt < effectiveNow else { return nil }
        return ActivityRibbon.Focus(id: "live", sessionID: nil, start: session.startedAt, end: effectiveNow,
                                    name: session.plan.goal.isEmpty ? "Focus" : session.plan.goal)
    }

    /// The project of the session running now, which the project filter is
    /// matched against.
    private var liveProjectID: UUID? { model.controller?.engine.session?.plan.projectID }

    /// The running session's bar, or nil when the project filter excludes it.
    private var filteredLiveFocus: ActivityRibbon.Focus? {
        ActivityFilterScope.includesLive(sessionProjectID: liveProjectID, filter: projectID) ? liveFocus : nil
    }

    var body: some View {
        let rangeSessions = displayedSessions
        let scope = displayedScope
        let isEmpty = rangeSessions.isEmpty && !scope.hasStretches && scope.totals.observed == 0
        return ScrollViewReader { proxy in
            NidusSettingsPage {
                hero
                filters(scope)
                if isEmpty {
                    emptyState
                } else {
                    overview(scope, sessions: rangeSessions)
                    if period == .today {
                        dayRibbon(scope, sessions: rangeSessions)
                    } else {
                        dailyPattern(scope.totals, sessions: rangeSessions)
                    }
                    weekGlance
                    if period != .today { trendsCard }
                    hourHeatmap
                    drift
                    ActivitySortCard(model: model, items: displayedUncategorized)
                    rankedList(displayedFiltered ?? scope.totals)
                    projectInsights
                    sessionList(rangeSessions)
                }
                NidusSettingsCard { ActivityTrackingControls(model: model) }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !isEmpty {
                    ActivitySectionBar(sections: ActivitySection.shown(for: period), tracker: tracker) { jump(to: $0, using: proxy) }
                }
            }
        }
        .sheet(item: $selectedSession) { entry in
            ActivitySessionRecap(entry: entry)
                .frame(minWidth: 430, minHeight: 440)
        }
        .onAppear { refreshProjects(); openInitialSession() }
        .onChange(of: period, initial: true) { _, value in tracker.order = ActivitySection.shown(for: value) }
        .task(id: requestedCacheKey) { await reload(requestedCacheKey) }
        .task(id: digestRequest) { await reloadDigest(digestRequest) }
        .task(id: comparisonRequest) { await reloadComparison(comparisonRequest) }
    }

    /// Scrolls a section to the top, and names it in the bar at once.
    private func jump(to section: ActivitySection, using proxy: ScrollViewProxy) {
        tracker.choose(section)
        if reduceMotion { proxy.scrollTo(section, anchor: .top) }
        else { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(section, anchor: .top) } }
    }

    private var hero: some View {
        NidusSettingsSection {
            VStack(alignment: .leading, spacing: 5) {
                Text("Activity")
                    .font(.solanum(.display))
                    .foregroundStyle(Solanum.ink)
                Text(model.activityAllDayEnabled ? "A record of your day: what was in front, and when."
                                                 : "A record of what was in front during focus sessions.")
                    .font(.solanum(.body))
                    .foregroundStyle(Solanum.inkMuted)
                if let end = model.activityPauseEnd {
                    HStack(spacing: 8) {
                        Text("Paused until \(end.formatted(date: .omitted, time: .shortened))")
                            .font(.solanum(.label))
                            .foregroundStyle(Solanum.clayText)
                        Button("Resume", action: model.resumeActivity)
                            .buttonStyle(.plain)
                            .font(.solanum(.label))
                            .foregroundStyle(Solanum.clayText)
                            .underline()
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.top, 4)
        } content: {
            EmptyView()
        }
    }

    private func filters(_ scope: ActivityScope) -> some View {
        NidusSettingsCard {
            HStack(spacing: 10) {
                // Reset here, not on a change of `period`: opening a day from
                // the week sets the period and its offset together.
                Picker("Time range", selection: Binding(get: { period }, set: { value in
                    guard value != period else { return }
                    period = value
                    periodOffset = 0
                    selectedDay = nil
                })) {
                    ForEach(ActivityPeriod.allCases) { value in Text(value.title).tag(value) }
                }
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
                    .font(.solanum(.caption, weight: .medium))
                    .foregroundStyle(Solanum.inkMuted)
                    .lineLimit(1)
                    .frame(maxWidth: 96)
            }
            .padding(.vertical, 4)
            if scope.hasDailyRecords || focusOnly {
                Toggle("During focus only", isOn: $focusOnly)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.solanum(.caption))
                    .foregroundStyle(Solanum.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.bottom, 2)
            }
        }
    }

    private var emptyState: some View {
        NidusSettingsCard {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.stack.badge.clock")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Solanum.clayText)
                Text("No activity in this view")
                    .font(.solanum(.title, weight: .medium))
                    .foregroundStyle(Solanum.ink)
                Text(model.activityAllDayEnabled
                     ? "Nothing was counted in the selected time range and project."
                     : "Activity appears here for recorded focus sessions in the selected time range and project. To see your whole day, turn on Track all day under Tracking.")
                    .font(.solanum(.label, weight: .regular))
                    .foregroundStyle(Solanum.inkMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
        }
    }

    private func overview(_ scope: ActivityScope, sessions: [SessionEntry]) -> some View {
        let totals = scope.totals
        let allDay = scope.hasDailyRecords && !focusOnly && projectID == nil
        let lines = comparisonLines(totals, allDay: allDay)
        return NidusSettingsCard {
            HStack(alignment: .center, spacing: 0) {
                ActivityFigure(label: allDay ? "At the Mac" : "Observed", value: ActivityDuration.string(totals.observed),
                               color: Solanum.ink, comparison: lines.observed)
                Divider().frame(height: 42)
                ActivityFigure(label: "In focus", value: ActivityDuration.string(totals.focused),
                               color: Solanum.clayText, comparison: lines.focused)
            }
            .padding(.top, 8)
            .activitySectionAnchor(.overview, tracker: tracker)
            Text(verbatim: ActivityOverviewLine.text(lead: totals.lead, sessions: sessions.count, withinFocus: !allDay))
                .font(.solanum(.label, weight: .regular))
                .foregroundStyle(Solanum.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }

    private func dayRibbon(_ scope: ActivityScope, sessions: [SessionEntry]) -> some View {
        let interval = requestedInterval
        let live = filteredLiveFocus.flatMap { interval.intersects(DateInterval(start: $0.start, end: $0.end)) ? $0 : nil }
        let byCategory = model.activityRibbonByCategory
        let ribbon = ActivityRibbon(stretches: scope.stretches, sessions: sessions, live: live, day: interval,
                                    now: effectiveNow, colorBy: byCategory ? .category(displayedCategorizer) : .app,
                                    calendar: calendar)
        return NidusSettingsCard {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Text("Color by")
                    .font(.solanum(.caption))
                    .foregroundStyle(Solanum.inkMuted)
                Picker("Color by", selection: Binding(get: { byCategory }, set: { model.activityRibbonByCategory = $0 })) {
                    Text("App").tag(false)
                    Text("Category").tag(true)
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Color the day by")
            }
            .padding(.top, 8)
            .activitySectionAnchor(.day, tracker: tracker)
            ActivityDayRibbon(ribbon: ribbon, calendar: calendar) { id in
                selectedSession = sessions.first { $0.id == id }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: Comparison with the usual weekday

    private struct ComparisonRequest: Equatable {
        let day: Date?
        let version: Int
        let projectID: UUID?
        let excluded: Set<String>
        let allDay: Bool
    }

    /// Only a single day is set against its weekday.
    private var comparisonRequest: ComparisonRequest {
        ComparisonRequest(day: period == .today ? requestedInterval.start : nil,
                          version: model.controller?.historyVersion ?? 0, projectID: projectID,
                          excluded: model.activityExcludedApps,
                          allDay: displayedScope.hasDailyRecords && !focusOnly && projectID == nil)
    }

    /// The quiet lines under the figures, or nil for a figure with too little
    /// history behind it.
    private func comparisonLines(_ totals: ActivityTotals, allDay: Bool) -> (observed: String?, focused: String?) {
        let day = requestedInterval.start
        guard period == .today, comparisonHistory.day == day else { return (nil, nil) }
        let weekday = ActivityComparison.weekdayName(of: day, calendar: calendar)
        let inProgress = requestedInterval.end > Date()
        let observed = allDay
            ? ActivityComparison.phrase(value: totals.observed, history: comparisonHistory.observed, weekday: weekday, inProgress: inProgress,
                                        format: ActivityDuration.string)
            : nil
        let focused = ActivityComparison.phrase(value: totals.focused, history: comparisonHistory.focused, weekday: weekday, inProgress: inProgress,
                                                format: ActivityDuration.string)
        return (observed, focused)
    }

    /// The earlier same weekdays' figures: focus from the saved sessions, and
    /// what was at the Mac from the saved day files.
    private func reloadComparison(_ request: ComparisonRequest) async {
        guard let day = request.day else {
            if comparisonHistory != ActivityComparisonHistory() { comparisonHistory = ActivityComparisonHistory() }
            return
        }
        let calendar = calendar
        let earlier = ActivityComparison.sameWeekdayDays(before: day, calendar: calendar)
        let wanted = Set(earlier)
        var focusedByDay: [Date: TimeInterval] = [:]
        for entry in sessions where request.projectID == nil || entry.projectID == request.projectID {
            let start = calendar.startOfDay(for: entry.start)
            if wanted.contains(start) { focusedByDay[start, default: 0] += max(0, entry.focused) }
        }
        var observedByDay: [Date: TimeInterval] = [:]
        if request.allDay, let recorder = model.controller?.activityRecorder {
            var dates: [String: Date] = [:]
            for date in earlier { dates[ActivityDayLog.key(for: date, calendar: calendar)] = date }
            let logs = await recorder.store.load(days: Array(dates.keys))
            let excluded = request.excluded
            let seconds = await Task.detached(priority: .utility) {
                logs.map { ($0.day, $0.hiding(excluded).seconds) }
            }.value
            guard !Task.isCancelled else { return }
            for (key, value) in seconds { if let date = dates[key] { observedByDay[date] = value } }
        }
        let history = ActivityComparisonHistory(
            day: day,
            observed: ActivityComparison.history(of: day, in: observedByDay, calendar: calendar),
            focused: ActivityComparison.history(of: day, in: focusedByDay, calendar: calendar))
        if history != comparisonHistory { comparisonHistory = history }
    }

    /// Holds a card's height while its data loads: an empty track, then the
    /// card fades in over it once.
    private func reserved<Content: View>(_ loaded: Bool, minHeight: CGFloat,
                                         @ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .top) {
            if !loaded {
                RoundedRectangle(cornerRadius: Solanum.frameRadius)
                    .fill(Solanum.track(contrast))
                    .frame(height: minHeight)
                    .accessibilityHidden(true)
            } else {
                content().transition(.opacity)
            }
        }
        .frame(minHeight: minHeight, alignment: .top)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: loaded)
    }

    /// Today alone says little about the shape of a week, so that view looks
    /// back four weeks. A week or a month covers itself.
    private var heatmapInterval: DateInterval {
        let shown = requestedInterval
        guard period == .today else { return shown }
        let start = calendar.date(byAdding: .day, value: -27, to: shown.start) ?? shown.start
        return DateInterval(start: start, end: shown.end)
    }

    /// The last day of the shown range, or today if the range isn't over.
    private var weekEnd: Date {
        let last = requestedInterval.end.addingTimeInterval(-1)
        return calendar.startOfDay(for: min(last, effectiveNow))
    }

    private var digestRequest: ActivityDigestRequest {
        let interval = heatmapInterval
        return ActivityDigestRequest(signature: .init(version: model.controller?.historyVersion ?? 0, excluded: model.activityExcludedApps,
                                                      work: model.workGroup, categories: model.categories,
                                                      overrides: model.activityOverrides),
                                     dayVersion: model.controller?.activityDayVersion ?? 0,
                                     start: interval.start, end: interval.end, shownStart: requestedInterval.start,
                                     weekEnd: weekEnd)
    }

    private var chartsIgnoreFilters: Bool {
        ActivityFilterScope.chartsIgnoreFilters(projectID: projectID, focusOnly: focusOnly, category: categoryFilter)
    }

    /// Says the chart under it is not narrowed by the filters above.
    private var unfilteredNote: some View {
        Text(ActivityFilterScope.unfilteredCaption)
            .font(.solanum(.caption))
            .foregroundStyle(Solanum.inkMuted)
    }

    private var weekGlance: some View {
        NidusSettingsSection {
            VStack(alignment: .leading, spacing: 3) {
                settingsSectionHeader("Week at a glance")
                Text("Seven days by category, against the seven before.")
                    .font(.solanum(.caption))
                    .foregroundStyle(Solanum.inkMuted)
                if chartsIgnoreFilters { unfilteredNote }
            }
            .activitySectionAnchor(.week, tracker: tracker)
        } content: {
            reserved(displayedWeek != nil, minHeight: 230) {
                if let displayedWeek {
                    ActivityWeekGlance(week: displayedWeek, calendar: calendar, openDay: open(day:))
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var trendsCard: some View {
        NidusSettingsSection {
            VStack(alignment: .leading, spacing: 3) {
                settingsSectionHeader("Trends")
                Text("Each category over the kept history: a month by day, a quarter by week.")
                    .font(.solanum(.caption))
                    .foregroundStyle(Solanum.inkMuted)
                if chartsIgnoreFilters { unfilteredNote }
            }
        } content: {
            reserved(displayedTrends != nil, minHeight: 205) {
                if let displayedTrends { ActivityTrendChart(trends: displayedTrends, calendar: calendar) }
            }
            .padding(.vertical, 8)
        }
    }

    private func open(day: Date) {
        let offset = ActivityPeriod.dayOffset(of: day, from: effectiveNow, calendar: calendar)
        if period != .today { period = .today }
        if periodOffset != offset { periodOffset = offset }
        if selectedDay != nil { selectedDay = nil }
    }

    private var hourHeatmap: some View {
        NidusSettingsSection {
            VStack(alignment: .leading, spacing: 3) {
                settingsSectionHeader("Hour by hour")
                Text(period == .today ? "The last four weeks, by weekday and hour." : "This range, by weekday and hour.")
                    .font(.solanum(.caption))
                    .foregroundStyle(Solanum.inkMuted)
                if chartsIgnoreFilters { unfilteredNote }
            }
            .activitySectionAnchor(.hours, tracker: tracker)
        } content: {
            reserved(digestLoaded, minHeight: 164) {
                ActivityHourHeatmap(map: displayedHeatmap, calendar: calendar, loadDetail: hourDetail)
            }
            .padding(.vertical, 8)
        }
    }

    /// Reads only the files that can hold the hour, away from the main actor.
    /// Finished days are read once for a selection; a save rereads only today.
    private func hourDetail(_ slot: ActivityHourSlot) async -> ActivityHourDetail? {
        guard let recorder = model.controller?.activityRecorder else { return nil }
        let interval = heatmapInterval, excluded = model.activityExcludedApps, calendar = calendar
        let days = ActivityHourDetail.days(of: slot, from: interval.start, to: interval.end, calendar: calendar)
        let today = ActivityDayLog.key(for: Date(), calendar: calendar)
        let past = days.filter { $0 != today }
        let finished = await digestCache.pastHour(slot, days: past, signature: digestRequest.signature) {
            let logs = await recorder.store.load(days: past)
            return await Task.detached(priority: .utility) {
                var detail = ActivityHourDetail(slot: slot)
                for log in logs { detail.add(log.hiding(excluded).stretches, calendar: calendar) }
                return detail
            }.value
        }
        guard days.contains(today) else { return finished }
        let written = recorder.isRecording ? recorder.today() : await recorder.store.load(days: [today]).first
        guard let written else { return finished }
        return await Task.detached(priority: .utility) {
            var detail = finished
            detail.add(written.hiding(excluded).stretches, calendar: calendar)
            return detail
        }.value
    }

    private var drift: some View {
        NidusSettingsSection {
            VStack(alignment: .leading, spacing: 3) {
                settingsSectionHeader("Drift")
                Text("Three minutes or more on one thing, then as long on a distraction straight after.")
                    .font(.solanum(.caption))
                    .foregroundStyle(Solanum.inkMuted)
                if chartsIgnoreFilters { unfilteredNote }
            }
            .activitySectionAnchor(.drift, tracker: tracker)
        } content: {
            reserved(displayedChains != nil, minHeight: 90) {
                if let displayedChains {
                    ActivityDriftList(chains: displayedChains, categorizer: displayedCategorizer)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func reloadDigest(_ request: ActivityDigestRequest) async {
        guard let recorder = model.controller?.activityRecorder else { return }
        let grid = dayKeys(from: request.start, to: request.end)
        let trending = period != .today
        let week = ActivityWeek.keys(ending: request.weekEnd, calendar: calendar)
            + (trending ? ActivityTrends.keys(ending: request.weekEnd, calendar: calendar) : [])
        let shownDays = dayKeys(from: request.shownStart, to: request.end)
        let today = ActivityDayLog.key(for: Date(), calendar: calendar)
        // Today is still being written, and the recorder has the latest of it.
        let written = recorder.isRecording ? recorder.today() : await recorder.store.load(days: [today]).first
        let excluded = request.signature.excluded
        let categorizer = ActivityCategorizer(categories: request.signature.categories, work: request.signature.work,
                                              overrides: request.signature.overrides)
        let digest = await digestCache.digest(grid: grid, week: week, chains: shownDays, today: today, live: written?.hiding(excluded),
                                              signature: request.signature, categorizer: categorizer, calendar: calendar) { missing in
            await recorder.store.load(days: missing).map { $0.hiding(excluded) }
        }
        guard !Task.isCancelled else { return }
        if digest.heatmap != displayedHeatmap { displayedHeatmap = digest.heatmap }
        if !digestLoaded { digestLoaded = true }
        let shown = ActivityWeek(ending: request.weekEnd, byDay: digest.byDay, categorizer: categorizer, calendar: calendar)
        if shown != displayedWeek { displayedWeek = shown }
        if trending {
            let trends = ActivityTrends(ending: request.weekEnd, byDay: digest.byDay, categorizer: categorizer, calendar: calendar)
            if trends != displayedTrends { displayedTrends = trends }
        }
        let chains = ActivityDrift.top(digest.chains.values)
        if chains != displayedChains { displayedChains = chains }
    }

    private func dailyPattern(_ totals: ActivityTotals, sessions: [SessionEntry]) -> some View {
        let colors = totals.serviceColors
        let parts = totals.services.map { item in
            ActivityDailyBars.Part(id: item.id == "__other__" ? "__other__" : item.name, name: item.name,
                                   color: colors[item.id] ?? Solanum.other)
        }
        return NidusSettingsSection {
            VStack(alignment: .leading, spacing: 3) {
                settingsSectionHeader("Daily pattern")
                Text("Observed time by the app or service in front.")
                    .font(.solanum(.label, weight: .regular))
                    .foregroundStyle(Solanum.inkMuted)
            }
            .activitySectionAnchor(.bars, tracker: tracker)
        } content: {
            NidusSettingsCard {
                ActivityDailyBars(buckets: totals.chartBuckets, period: period,
                                  anchor: period.anchor(offset: periodOffset, from: effectiveNow, calendar: calendar),
                                  calendar: calendar, parts: parts, selectedDay: $selectedDay)
                    .padding(.top, 6)
                HStack(spacing: 14) {
                    ForEach(parts) { part in
                        ActivityLegend(color: part.color, title: part.name)
                    }
                }
                .font(.solanum(.caption))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 3)
            }
        }
    }

    private var projectInsights: some View {
        let values = displayedInsights
        guard !values.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(NidusSettingsSection {
            VStack(alignment: .leading, spacing: 3) {
                settingsSectionHeader("Project insight")
                Text("Observed activity across projects in this time range.")
                    .font(.solanum(.label, weight: .regular))
                    .foregroundStyle(Solanum.inkMuted)
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
                                    .font(.solanum(.label))
                                    .foregroundStyle(Solanum.ink)
                                    .lineLimit(1)
                                Text(item.lead.map { "Most observed: \($0.name)" } ?? "No observed activity")
                                    .font(.solanum(.caption))
                                    .foregroundStyle(Solanum.inkMuted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(ActivityDuration.string(item.observed))
                                    .font(.solanum(.caption, weight: .medium, design: .rounded))
                                    .foregroundStyle(Solanum.inkMuted)
                                    .monospacedDigit()
                                Text("\(item.sessionCount) \(item.sessionCount == 1 ? "session" : "sessions")")
                                    .font(.solanum(.caption))
                                    .foregroundStyle(Solanum.inkMuted)
                            }
                            Image(systemName: "chevron.right")
                                .font(.solanum(.caption, weight: .semibold))
                                .foregroundStyle(Solanum.inkFaint)
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

    private func rankedList(_ totals: ActivityTotals) -> some View {
        let rows: [ActivityRank]
        switch listKind {
        case .apps: rows = totals.apps
        case .websites: rows = totals.sites
        case .documents: rows = totals.documents
        case .categories: rows = []
        }
        let categories = displayedCategories
        let count = listKind == .categories ? categories.count : rows.count
        let limit = expandedList ? count : 5
        return NidusSettingsCard {
            if let categoryFilter { filterChip(categoryFilter) }
            Picker("Show", selection: $listKind) {
                ForEach(ActivityListKind.allCases) { kind in Text(kind.title).tag(kind) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .activitySectionAnchor(.apps, tracker: tracker)
            .accessibilityLabel("Rank activity by")
            .onChange(of: listKind) { _, _ in expandedList = false }
            .padding(.vertical, 6)
            if count == 0 {
                Text(listKind.emptyNote)
                    .font(.solanum(.caption))
                    .foregroundStyle(Solanum.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            }
            if listKind == .categories {
                ForEach(Array(categories.prefix(limit))) { item in
                    ActivityCategoryRow(item: item, selected: item.id == categoryFilter,
                                        tint: ActivityInk.series(displayedCategorizer.tint(of: item.id))) {
                        categoryFilter = item.id
                        listKind = .apps
                    }
                }
            } else {
                ForEach(Array(rows.prefix(limit).enumerated()), id: \.element.id) { index, row in
                    let details = listKind == .apps ? totals.appDetails[row.id] ?? [] : []
                    ActivityRankRow(rank: index + 1, item: row, maximum: rows.first?.seconds ?? row.seconds,
                                    tint: listKind == .apps ? ActivityInk.app(row.id) : Solanum.inkMuted,
                                    reopen: listKind == .apps ? nil : row.reopenTarget.map { target in { target.perform() } },
                                    expansion: details.isEmpty ? nil : openRows.contains(row.id),
                                    toggle: { toggle(row.id) })
                        .activityCountAs(model: model, target: ActivityCountTarget(rank: row, kind: listKind))
                    if openRows.contains(row.id), !details.isEmpty {
                        ActivityDrillList(appID: row.id, details: details, open: openRows, toggle: toggle)
                    }
                }
            }
            if count > 5 {
                Button(expandedList ? "Show less" : "Show all \(count)") {
                    if reduceMotion { expandedList.toggle() }
                    else { withAnimation(.easeInOut(duration: 0.2)) { expandedList.toggle() } }
                }
                .buttonStyle(.plain)
                .font(.solanum(.caption, weight: .medium))
                .foregroundStyle(Solanum.clayText)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 3)
                .accessibilityHint("Expands the ranked list")
            }
        }
    }

    private func toggle(_ id: String) {
        let change = { if openRows.remove(id) == nil { openRows.insert(id) } }
        if reduceMotion { change() } else { withAnimation(.easeInOut(duration: 0.18)) { change() } }
    }

    /// What the lists are cut to, and the way back.
    private func filterChip(_ id: String) -> some View {
        let label = displayedCategorizer.label(of: id == ActivityCategorizer.uncategorizedID ? nil : id)
        return HStack(spacing: 6) {
            Image(systemName: label.symbol)
                .font(.solanum(.caption, weight: .medium))
                .foregroundStyle(Solanum.clayText)
                .accessibilityHidden(true)
            Text(verbatim: "Only \(label.name)")
                .font(.solanum(.caption, weight: .medium))
                .foregroundStyle(Solanum.clayText)
                .lineLimit(1)
            Button {
                categoryFilter = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.solanum(.caption))
                    .foregroundStyle(Solanum.inkMuted)
            }
            .buttonStyle(.plain)
            .help("Show everything again")
            .accessibilityLabel("Clear the \(label.name) filter")
            Text("Figures above cover everything.")
                .font(.solanum(.caption))
                .foregroundStyle(Solanum.inkMuted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.top, 6)
    }

    private func sessionList(_ scoped: [SessionEntry]) -> some View {
        let rows = selectedDay.map { day in scoped.filter { calendar.isDate($0.start, inSameDayAs: day) } } ?? scoped
        return NidusSettingsSection {
            VStack(alignment: .leading, spacing: 3) {
                settingsSectionHeader("Session recaps")
                Text("Open a session to see its observed activity.")
                    .font(.solanum(.label, weight: .regular))
                    .foregroundStyle(Solanum.inkMuted)
            }
            .activitySectionAnchor(.sessions, tracker: tracker)
        } content: {
            NidusSettingsCard {
                if let selectedDay {
                    HStack {
                        Text("Sessions on \(selectedDay.formatted(date: .abbreviated, time: .omitted))")
                        Spacer()
                        Button("Clear") { self.selectedDay = nil }
                    }
                    .font(.solanum(.caption))
                    .foregroundStyle(Solanum.inkMuted)
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
                    .font(.solanum(.caption, weight: .medium))
                    .foregroundStyle(Solanum.clayText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private func openInitialSession() {
        guard let initialSessionID, let entry = sessions.first(where: { $0.id == initialSessionID }) else { return }
        selectedSession = entry
    }

    private func refreshProjects() {
        let version = model.controller?.historyVersion ?? 0
        guard displayedProjectsVersion != version else { return }
        var seen = Set<UUID>()
        displayedProjects = sessions.compactMap { entry in
            guard let id = entry.projectID, let name = entry.projectName, !name.isEmpty,
                  seen.insert(id).inserted else { return nil }
            return ActivityProjectChoice(id: id, name: name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        displayedProjectsVersion = version
    }

    /// Daily files come off the main actor; today's comes from the recorder
    /// when it is running, since that includes the stretch still open.
    private func reload(_ key: ActivityCacheKey) async {
        refreshProjects()
        let narrowed = key.focusOnly || key.projectID != nil
        let inRange: [SessionEntry]
        let scope: ActivityScope
        if !narrowed, let loaded = displayedLoadKey, loaded.scope == key.scope {
            // Only the groups changed (an edit, "Count as", a filter): the
            // same files would give the same scope. A narrowed view isn't
            // reused, since its slice of the live session moves with the clock.
            inRange = displayedSessions
            scope = displayedScope
        } else {
            inRange = sessions.filter { entry in
                key.start <= entry.start && entry.start < key.end
                    && (key.projectID == nil || entry.projectID == key.projectID)
            }.sorted { $0.start > $1.start }
            let recorder = model.controller?.activityRecorder
            let days = dayKeys(from: key.start, to: key.end)
            // A newer reload cancels this one; it stops reading files then.
            var read: [ActivityDayLog]? = []
            if let recorder { read = await recorder.store.loadUnlessCancelled(days: days) }
            guard var logs = read, !Task.isCancelled else { return }
            logs = logs.map { $0.hiding(key.excluded) }
            if let recorder, recorder.isRecording {
                let today = recorder.today()
                if days.contains(today.day) {
                    logs.removeAll { $0.day == today.day }
                    logs.append(today.hiding(key.excluded))
                }
            }
            let live = liveFocus.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
            // Only a single day draws the ribbon, so a week or month doesn't
            // keep a sorted copy of every stretch in it.
            scope = ActivityScope(logs: logs, sessions: inRange, narrowed: narrowed,
                                  live: ActivityFilterScope.includesLive(sessionProjectID: liveProjectID, filter: key.projectID) ? live : nil, includeTimeline: key.includeTimeline,
                                  calendar: calendar)
        }
        let categorizer = key.categorizer
        // A filter on a category that has since been deleted is dropped.
        let known = [ActivityCategorizer.workID, ActivityCategorizer.uncategorizedID] + key.categories.map(\.id)
        let filter = key.categoryFilter.flatMap { known.contains($0) ? $0 : nil }
        displayedSessions = inRange
        displayedInsights = ActivityProjectInsights.summaries(sessions: sessions, interval: DateInterval(start: key.start, end: key.end),
                                                              calendar: calendar)
        displayedScope = scope
        displayedCategorizer = categorizer
        displayedCategories = scope.categoryTotals(using: categorizer)
        displayedUncategorized = ActivityUncategorized.items(stretches: scope.categoryStretches,
                                                             rows: scope.categoryRows.map(\.row),
                                                             using: categorizer, overrides: key.overrides)
        displayedFiltered = filter.map { scope.totals(in: $0, using: categorizer, calendar: calendar) }
        if filter != key.categoryFilter { categoryFilter = nil }
        displayedLoadKey = key
    }

    private func dayKeys(from start: Date, to end: Date) -> [String] {
        var keys: [String] = []
        var day = calendar.startOfDay(for: start)
        while day < end {
            keys.append(ActivityDayLog.key(for: day, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return keys
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

struct ActivityCacheKey: Equatable {
    let version: Int
    let dayVersion: Int
    let start: Date
    let end: Date
    let projectID: UUID?
    let focusOnly: Bool
    let excluded: Set<String>
    /// What the groups hold, so editing one (or "Count as") reads back.
    let work: FocusCategory
    let categories: [FocusCategory]
    let overrides: ActivityOverrides
    let categoryFilter: String?
    /// A single day: the scope keeps its stretches for the ribbon.
    var includeTimeline = true

    /// What the scope is built from; the rest only changes how it's grouped.
    struct Scope: Equatable {
        let version: Int
        let dayVersion: Int
        let start: Date
        let end: Date
        let projectID: UUID?
        let focusOnly: Bool
        let excluded: Set<String>
        let includeTimeline: Bool
    }
    var scope: Scope {
        Scope(version: version, dayVersion: dayVersion, start: start, end: end, projectID: projectID,
              focusOnly: focusOnly, excluded: excluded, includeTimeline: includeTimeline)
    }

    /// The 2-minute day-file save only changes today's numbers, so a range
    /// that's over keeps its cached load instead of reading its files again.
    static func dayVersion(_ version: Int, start: Date, end: Date, now: Date) -> Int {
        start <= now && now < end ? version : 0
    }

    /// The groups as the popover has them, "Count as" included.
    var categorizer: ActivityCategorizer {
        ActivityCategorizer(categories: categories, work: work, overrides: overrides)
    }
}

/// The one ranked list's three views of the same seconds, which is why they
/// never add up to each other.
enum ActivityListKind: String, CaseIterable, Identifiable {
    case apps, websites, documents, categories
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// The popover ranks these; categories are a line there, not a list.
    static let popoverKinds: [ActivityListKind] = [.apps, .websites, .documents]
    /// Neutral ink: a list's own colour means nothing. Apps and categories
    /// take their stable hue per row instead (the popover keeps this one).
    var tint: Color { Solanum.inkMuted }
    var emptyNote: String {
        switch self {
        case .apps: return "No apps were counted here."
        case .websites: return "No websites here. Allow website access browser by browser under Tracking."
        case .documents: return "No documents or coding projects here. Allow window-title access under Tracking."
        case .categories: return "Nothing to sort into categories here."
        }
    }
}

enum ActivityOverviewLine {
    static func text(lead: ActivityRank?, sessions: Int, withinFocus: Bool) -> String {
        let count = "\(sessions) focus \(sessions == 1 ? "session" : "sessions")"
        guard let lead else { return sessions == 0 ? "Nothing was counted." : "Across \(count), with nothing observed." }
        let most = "Most of it in \(lead.name), \(ActivityDuration.string(lead.seconds))"
        if sessions == 0 { return most + "." }
        return most + (withinFocus ? ", across \(count)." : ", with \(count).")
    }
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

    /// The Today offset that shows `day`. Never ahead of today.
    static func dayOffset(of day: Date, from now: Date, calendar: Calendar = .current) -> Int {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: day)).day
        return min(0, days ?? 0)
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
        return "\(totalSeconds) sec"
    }
}

/// The Activity charts' colours, read from Solanum's palette
/// (SolanumTokens.swift): one meaning per colour.
enum ActivityInk {
    /// Focus, and only focus.
    static let clay = Solanum.focus
    /// The tint for time that belongs to no one thing.
    nonisolated static let quietTint = ActivityTint.quiet
    /// A tint (ActivityTint, or a palette slot) as a colour.
    static func series(_ tint: Int) -> Color {
        switch tint {
        case ActivityTint.work: return Solanum.work
        case ..<0: return Solanum.other
        default: return Solanum.series(tint)
        }
    }
    /// An app's colour: the same hue for the same app everywhere.
    static func app(_ key: String) -> Color { Solanum.series(ActivityTint.app(key)) }
}

struct ActivityTotals {
    var focused: TimeInterval = 0
    var observed: TimeInterval = 0
    var apps: [ActivityRank] = []
    var sites: [ActivityRank] = []
    var documents: [ActivityRank] = []
    var services: [ActivityRank] = []
    /// What's inside each app, by app id.
    var appDetails: [String: [ActivityDrill]] = [:]
    var chartBuckets: [Date: [String: TimeInterval]] = [:]

    var lead: ActivityRank? { services.first }
    init(sessions: [SessionEntry], calendar: Calendar = .current) {
        self.init(rows: sessions.flatMap { session in
            let day = calendar.startOfDay(for: session.start)
            return Self.rows(of: session).map { (day, $0) }
        }, focused: sessions.reduce(0) { $0 + max(0, $1.focused) })
    }

    /// A session's rows. Legacy records have an app-only foreground map: that
    /// coverage stays visible, without implying websites or titles exist.
    static func rows(of session: SessionEntry) -> [FocusActivity] {
        if let activity = session.activity { return activity }
        return session.foreground.map { appID, seconds in
            FocusActivity(id: appID, appID: appID, appName: session.names[appID] ?? appID, seconds: seconds)
        }
    }

    /// What a stretch of time counts as in a chart or ribbon. A recognized
    /// service stands on its own; any other site is time in its browser, so
    /// one day's reading doesn't scatter into a color per domain.
    static func series(site: String?, appName: String) -> String {
        ActivityTimeline.safeSite(site) ?? appName
    }

    init(rows: [(day: Date, row: FocusActivity)], focused: TimeInterval) {
        self.focused = focused
        var appSeconds: [String: TimeInterval] = [:]
        var siteSeconds: [String: TimeInterval] = [:]
        var documentSeconds: [String: TimeInterval] = [:]
        var documentTitles: [String: String] = [:]
        var documentSources: [String: String] = [:]
        var documentApps: [String: String] = [:]
        var documentSites: [String: String] = [:]
        var documentAppNames: [String: String] = [:]
        var projectAppSeconds: [String: [String: TimeInterval]] = [:]
        var projectAppIDs: [String: [String: String]] = [:]
        var siteApps: [String: (id: String, name: String)] = [:]
        var appNames: [String: String] = [:]
        var serviceSeconds: [String: TimeInterval] = [:]
        var serviceSecondsByDay: [Date: [String: TimeInterval]] = [:]
        for (day, item) in rows where item.seconds > 0 {
            observed += item.seconds
            appNames[item.appID] = item.appName
            appSeconds[item.appID, default: 0] += item.seconds
            let service = Self.series(site: item.site, appName: item.appName)
            serviceSeconds[service, default: 0] += item.seconds
            serviceSecondsByDay[day, default: [:]][service, default: 0] += item.seconds
            let isDocument = ActivityTimeline.isDocumentService(item.site)
            if let site = item.site, !site.isEmpty, !isDocument {
                siteSeconds[site, default: 0] += item.seconds
                siteApps[site] = (item.appID, item.appName)
            }
            if let title = ActivityTimeline.documentName(appID: item.appID, title: item.title, site: item.site),
               !title.isEmpty {
                let key = Self.documentKey(appID: item.appID, site: item.site, title: title)
                documentSeconds[key, default: 0] += item.seconds
                documentTitles[key] = title
                if ActivityProjectTitle.isProjectApp(item.appID) {
                    // One project across Xcode, VS Code and a terminal.
                    projectAppSeconds[key, default: [:]][item.appName, default: 0] += item.seconds
                    projectAppIDs[key, default: [:]][item.appName] = item.appID
                } else {
                    documentSources[key] = [item.site, item.appName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    documentApps[key] = item.appID
                    documentAppNames[key] = item.appName
                    documentSites[key] = item.site
                }
            }
        }
        for (key, byApp) in projectAppSeconds {
            // Named after its apps, longest first; it counts as the app it
            // had the most time in.
            let ordered = byApp.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
            documentSources[key] = "Project · " + ordered.joined(separator: ", ")
            documentAppNames[key] = ordered.first
            documentApps[key] = ordered.first.flatMap { projectAppIDs[key]?[$0] }
        }
        apps = Self.ranked(appSeconds, names: appNames)
        appDetails = ActivityDrill.tree(rows.map(\.row))
        sites = Self.ranked(siteSeconds).map { rank in
            var rank = rank
            rank.sourceAppID = siteApps[rank.id]?.id
            rank.sourceAppName = siteApps[rank.id]?.name
            return rank
        }
        documents = documentSeconds.map { key, seconds in
            ActivityRank(id: key, name: documentTitles[key] ?? key, seconds: seconds, subtitle: documentSources[key],
                         appID: documentApps[key], site: documentSites[key], appName: documentAppNames[key])
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

    /// A document is its app's, site's and title's; a coding project is its
    /// name alone, whichever coding app it was open in.
    static func documentKey(appID: String, site: String?, title: String) -> String {
        if ActivityProjectTitle.isProjectApp(appID) { return "project\u{1F}\(title)" }
        return "\(appID)\u{1F}\(site ?? "")\u{1F}\(title)"
    }

    /// Gives sites and documents the last address each was seen at, from
    /// stretches in time order.
    /// The latest address of each site and document. `stretches` need not be
    /// in time order: the one starting last wins, and of two starting
    /// together, the later in the list (as a stable sort would leave them).
    mutating func noteAddresses(from stretches: [FocusActivitySegment]) {
        var bySite: [String: (start: Date, url: String)] = [:]
        var byDocument: [String: (start: Date, url: String)] = [:]
        for stretch in stretches {
            guard let url = stretch.url else { continue }
            if let site = stretch.site, bySite[site].map({ stretch.start >= $0.start }) ?? true {
                bySite[site] = (stretch.start, url)
            }
            if let title = ActivityTimeline.documentName(appID: stretch.appID, title: stretch.title, site: stretch.site) {
                let key = Self.documentKey(appID: stretch.appID, site: stretch.site, title: title)
                if byDocument[key].map({ stretch.start >= $0.start }) ?? true { byDocument[key] = (stretch.start, url) }
            }
        }
        for index in sites.indices { sites[index].url = bySite[sites[index].id]?.url }
        for index in documents.indices { documents[index].url = byDocument[documents[index].id]?.url }
    }

    private static func ranked(_ values: [String: TimeInterval], names: [String: String] = [:]) -> [ActivityRank] {
        values.map { key, seconds in ActivityRank(id: key, name: names[key] ?? key, seconds: seconds) }
            .sorted { $0.seconds == $1.seconds ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : $0.seconds > $1.seconds }
    }
}

extension ActivityTotals {
    /// Each service's colour by id, the same wherever it is drawn: an app's
    /// is its bundle id's hue, a site's its name's, and Other is quiet. Never
    /// the service's rank.
    var serviceColors: [String: Color] {
        let appIDs = Dictionary(apps.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        return Dictionary(services.map { service -> (String, Color) in
            let color = service.id == "__other__" ? ActivityInk.series(ActivityTint.quiet)
                                                  : ActivityInk.app(appIDs[service.name] ?? service.id)
            return (service.id, color)
        }, uniquingKeysWith: { first, _ in first })
    }
}

struct ActivityRank: Identifiable {
    var id: String
    var name: String
    var seconds: TimeInterval
    var subtitle: String? = nil
    /// A document's app.
    var appID: String? = nil
    /// The address it was last seen at.
    var url: String? = nil
    /// A document's site, when it was a page.
    var site: String? = nil
    /// A document's app, by name.
    var appName: String? = nil
    /// The app a website was last seen in. Not a place to reopen it: it is
    /// what "Count as" falls back on for a site that is only a label.
    var sourceAppID: String? = nil
    var sourceAppName: String? = nil
}

extension ActivityCategoryTotal {
    /// "42%"; "<1%" for a sliver, so a row never reads 0%.
    var percentText: String {
        let percent = Int((share * 100).rounded())
        return percent == 0 && seconds > 0 ? "<1%" : "\(percent)%"
    }
}

/// A group, its time and its share of all the time counted. Choosing it
/// cuts the lists to it.
private struct ActivityCategoryRow: View {
    let item: ActivityCategoryTotal
    let selected: Bool
    /// The category's stable hue.
    let tint: Color
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    Image(systemName: item.symbol)
                        .font(.solanum(.caption))
                        .foregroundStyle(selected ? Solanum.clayText : Solanum.inkMuted)
                        .frame(width: 22, alignment: .leading)
                        .accessibilityHidden(true)
                    Text(verbatim: item.name)
                        .font(.solanum(.label))
                        .foregroundStyle(Solanum.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(item.percentText)
                        .font(.solanum(.caption, weight: .medium, design: .rounded))
                        .foregroundStyle(Solanum.inkMuted)
                        .monospacedDigit()
                    Text(ActivityDuration.string(item.seconds))
                        .font(.solanum(.caption, weight: .medium, design: .rounded))
                        .foregroundStyle(Solanum.inkMuted)
                        .monospacedDigit()
                        .frame(minWidth: 52, alignment: .trailing)
                }
                SolanumMagnitudeBar(fraction: item.share, color: tint)
                    .padding(.leading, 31)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show only \(item.name) in the lists")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(ActivityDuration.string(item.seconds)), \(item.percentText)")
        .accessibilityHint("Shows only this category in the lists")
    }
}

private struct ActivityFigure: View {
    let label: String
    let value: String
    let color: Color
    /// One quiet line under the figure ("40 min more than your usual
    /// Tuesday"); nil leaves none.
    var comparison: String? = nil
    var small = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.solanum(.caption)).foregroundStyle(Solanum.inkMuted)
            Text(verbatim: value)
                .font(small ? .solanumFigureSmall : .solanumFigure)
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let comparison {
                Text(verbatim: comparison)
                    .font(.solanum(.caption))
                    .foregroundStyle(Solanum.inkMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }
}

struct ActivityLegend: View {
    let color: Color
    let title: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).foregroundStyle(Solanum.inkMuted)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ActivityRankRow: View {
    let rank: Int
    let item: ActivityRank
    let maximum: TimeInterval
    let tint: Color
    /// Goes back to the page or document, where the row has somewhere to go.
    var reopen: (() -> Void)? = nil
    /// Whether the row is open, where it has anything inside.
    var expansion: Bool? = nil
    var toggle: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        if let expansion {
            Button(action: toggle) { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityValue(expansion ? "Open" : "Closed")
                .accessibilityHint(expansion ? "Hides what's inside" : "Shows what's inside")
        } else if let reopen {
            Button(action: reopen) { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(item.url == nil ? "Open the app" : "Open again")
                .accessibilityHint(item.url == nil ? "Opens the app" : "Opens the page")
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Text(String(format: "%02d", rank))
                    .font(.solanum(.overline, weight: .medium))
                    .foregroundStyle(Solanum.inkFaint)
                    .frame(width: 22, alignment: .leading)
                Text(verbatim: item.name)
                    .font(.solanum(.label))
                    .foregroundStyle(Solanum.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if reopen != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.solanum(.caption, weight: .semibold))
                        .foregroundStyle(Solanum.clayText)
                        .opacity(hovering ? 1 : 0)
                        .accessibilityHidden(true)
                }
                Text(ActivityDuration.string(item.seconds))
                    .font(.solanum(.caption, weight: .medium, design: .rounded))
                    .foregroundStyle(Solanum.inkMuted)
                    .monospacedDigit()
                if let expansion {
                    Image(systemName: "chevron.right")
                        .font(.solanum(.caption, weight: .semibold))
                        .foregroundStyle(Solanum.inkFaint)
                        .rotationEffect(.degrees(expansion ? 90 : 0))
                        .accessibilityHidden(true)
                }
            }
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(.solanum(.caption))
                    .foregroundStyle(Solanum.inkFaint)
                    .lineLimit(1)
                    .padding(.leading, 31)
            }
            SolanumMagnitudeBar(fraction: maximum > 0 ? item.seconds / maximum : 0, color: tint)
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
            RoundedRectangle(cornerRadius: Solanum.markRadius).fill(hasDetails ? Solanum.focus : Solanum.other)
                .frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        .font(.solanum(.caption, weight: .medium))
                        .foregroundStyle(Solanum.ink)
                    Text(entry.start.formatted(.dateTime.hour().minute()))
                        .font(.solanum(.caption))
                        .foregroundStyle(Solanum.inkMuted)
                    if !hasDetails {
                        Text("APP ONLY")
                            .font(.solanum(.caption, weight: .semibold, design: .rounded))
                            .tracking(0.4)
                            .foregroundStyle(Solanum.inkMuted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Solanum.track, in: Capsule())
                    }
                }
                Text(entry.goal.isEmpty ? (entry.projectName ?? "Focus session") : entry.goal)
                    .font(.solanum(.label, weight: .regular))
                    .foregroundStyle(Solanum.inkMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(ActivityDuration.string(entry.focused))
                    .font(.solanum(.caption, weight: .semibold, design: .rounded))
                    .foregroundStyle(Solanum.ink)
                Text("\(ActivityDuration.string(observed)) observed")
                    .font(.solanum(.caption))
                    .foregroundStyle(Solanum.inkMuted)
            }
            Image(systemName: "chevron.right")
                .font(.solanum(.caption, weight: .semibold))
                .foregroundStyle(Solanum.inkFaint)
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
                            .font(.solanum(.display))
                            .foregroundStyle(Solanum.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(entry.start.formatted(.dateTime.weekday(.wide).month(.wide).day()) + " · " + entry.start.formatted(.dateTime.hour().minute()))
                            .font(.solanum(.label, weight: .regular))
                            .foregroundStyle(Solanum.inkMuted)
                    }
                    HStack(spacing: 0) {
                        ActivityFigure(label: "Focused", value: ActivityDuration.string(entry.focused), color: Solanum.clayText)
                        Divider().frame(height: 40)
                        ActivityFigure(label: "Observed", value: ActivityDuration.string(observed), color: Solanum.ink)
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
                            .font(.solanum(.label, weight: .regular))
                            .foregroundStyle(Solanum.inkMuted)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var composition: some View {
        let sessionTotals = ActivityTotals(sessions: [entry])
        let services = sessionTotals.services
        let colors = sessionTotals.serviceColors
        let total = services.reduce(0) { $0 + $1.seconds }
        return VStack(alignment: .leading, spacing: 9) {
            if total > 0 {
                Text("Where this session went")
                    .font(.solanum(.label))
                    .foregroundStyle(Solanum.inkMuted)
                GeometryReader { proxy in
                    HStack(spacing: 3) {
                        ForEach(services) { service in
                            RoundedRectangle(cornerRadius: Solanum.markRadius)
                                .fill(colors[service.id] ?? Solanum.other)
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
            if !sites.isEmpty { recapGroup("Websites", rows: sites) }
            if !documents.isEmpty { recapGroup("Documents", rows: documents) }
            if activity.isEmpty {
                Text("No activity details were observed during this session.")
                    .font(.solanum(.label, weight: .regular)).foregroundStyle(Solanum.inkMuted)
            }
        }
    }

    private var legacyRecap: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("App-only coverage", systemImage: "info.circle")
                .font(.solanum(.label)).foregroundStyle(Solanum.inkMuted)
            Text("Detailed activity was not recorded for this session. Any available app totals are shown below.")
                .font(.solanum(.label, weight: .regular)).foregroundStyle(Solanum.inkMuted)
            recapGroup("Apps observed", rows: legacyApps)
        }
    }

    private func recapGroup(_ title: String, rows: [ActivityRank]) -> some View {
        ActivityRecapGroup(title: title, rows: rows)
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
            guard let title = ActivityTimeline.documentName(appID: item.appID, title: item.title, site: item.site),
                  !title.isEmpty else { continue }
            let key = "\(item.appID)\u{1F}\(item.site ?? "")\u{1F}\(title)"
            secondsByKey[key, default: 0] += max(0, item.seconds)
            titles[key] = title
            sources[key] = [item.site, item.appName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return secondsByKey.map { key, seconds in
            ActivityRank(id: key, name: titles[key] ?? key, seconds: seconds, subtitle: sources[key])
        }.sorted { $0.seconds > $1.seconds }
    }
}

/// One list in a recap. Long lists start short, and all of it is one click
/// away: nothing a session holds is out of reach.
private struct ActivityRecapGroup: View {
    static let collapsedCount = 12
    let title: String
    let rows: [ActivityRank]
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.solanum(.caption, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Solanum.inkMuted)
            if rows.isEmpty {
                Text("No time recorded").font(.solanum(.caption)).foregroundStyle(Solanum.inkFaint)
            } else {
                ForEach(expanded ? rows : Array(rows.prefix(Self.collapsedCount))) { row in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: row.name).lineLimit(1).truncationMode(.middle)
                            if let subtitle = row.subtitle, !subtitle.isEmpty {
                                Text(verbatim: subtitle).font(.solanum(.caption)).foregroundStyle(Solanum.inkFaint).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(ActivityDuration.string(row.seconds)).monospacedDigit()
                    }
                    .font(.solanum(.label, weight: .regular))
                    .foregroundStyle(Solanum.ink)
                    .padding(.vertical, 3)
                }
                if rows.count > Self.collapsedCount {
                    Button(expanded ? "Show fewer" : "Show all \(rows.count)") {
                        if reduceMotion { expanded.toggle() }
                        else { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }
                    }
                    .buttonStyle(.plain)
                    .font(.solanum(.caption, weight: .medium))
                    .foregroundStyle(Solanum.clayText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .padding(12)
        .background(Solanum.track(contrast), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ActivitySessionTimeline: View {
    let entry: SessionEntry
    @State private var expanded = false
    @Environment(\.colorSchemeContrast) private var contrast

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
                .font(.solanum(.label))
                .foregroundStyle(Solanum.inkMuted)
            if let segments = entry.activitySegments {
                HStack(spacing: 0) {
                    ActivityTimelineMetric(label: "Context switches", value: "\(entry.activitySwitchCount ?? 0)", color: Solanum.ink)
                    Divider().frame(height: 34)
                    ActivityTimelineMetric(label: "Document switches", value: "\(documentSwitches)", color: Solanum.ink)
                    Divider().frame(height: 34)
                    ActivityTimelineMetric(label: entry.activityTimelineTruncated == true ? "Longest retained context stretch" : "Longest same-context stretch",
                                           value: ActivityDuration.string(entry.longestObservedStretch ?? 0), color: Solanum.ink)
                }
                .padding(.vertical, 4)
                if entry.activityTimelineTruncated == true {
                    Label("Earlier observations were omitted; metrics describe the retained timeline.", systemImage: "info.circle")
                        .font(.solanum(.caption))
                        .foregroundStyle(Solanum.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if segments.isEmpty {
                    Text("No activity intervals were observed during this session.")
                        .font(.solanum(.caption))
                        .foregroundStyle(Solanum.inkMuted)
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
                        .font(.solanum(.caption, weight: .medium))
                        .foregroundStyle(Solanum.clayText)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            } else {
                Label("Timeline unavailable for this older session", systemImage: "clock.badge.questionmark")
                    .font(.solanum(.caption, weight: .medium))
                    .foregroundStyle(Solanum.inkMuted)
                Text("This session has app totals, but no ordered observations were saved. Context switches and uninterrupted stretches cannot be determined.")
                    .font(.solanum(.caption))
                    .foregroundStyle(Solanum.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Solanum.track(contrast), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ActivityTimelineMetric: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.solanum(.caption, weight: .medium))
                .foregroundStyle(Solanum.inkMuted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: value)
                .font(.solanumFigureSmall)
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
                Circle().fill(Solanum.inkMuted).frame(width: 7, height: 7)
                Rectangle().fill(Solanum.hairline).frame(width: 1).frame(minHeight: 30)
                    .opacity(isLast ? 0 : 1)
            }
            .frame(width: 8)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(block.start.formatted(.dateTime.hour().minute()) + "–" + block.end.formatted(.dateTime.hour().minute()))
                        .font(.solanum(.overline, weight: .medium))
                        .foregroundStyle(Solanum.inkMuted)
                    Spacer(minLength: 4)
                    Text(ActivityDuration.string(block.seconds))
                        .font(.solanum(.caption, weight: .medium, design: .rounded))
                        .foregroundStyle(Solanum.inkMuted)
                        .monospacedDigit()
                }
                Text(block.contextName)
                    .font(.solanum(.caption, weight: .medium))
                    .foregroundStyle(Solanum.ink)
                    .lineLimit(1)
                if let detail = block.detail {
                    Text(detail).font(.solanum(.caption)).foregroundStyle(Solanum.inkMuted).lineLimit(1)
                } else if block.firstSegment.site != nil {
                    Text(block.appName).font(.solanum(.caption)).foregroundStyle(Solanum.inkMuted).lineLimit(1)
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
        .font(.solanum(.caption, weight: .medium))
        .foregroundStyle(Solanum.inkMuted)
        .padding(.leading, 18)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}
