//
//  NidusWidget.swift
//  NidusWidget (the widget extension, Contents/PlugIns/NidusWidget.appex)
//
//  The desktop widget (small and medium): the goal and the time left while a
//  session runs, the break while one runs, and the setups to start when
//  nothing does. And two Control Center controls: Start Nidus (the first
//  setup, or the popover when there is none) and End Nidus Session.
//
//  The extension is sandboxed and reads one file, widget.json in Nidus's
//  folder (WidgetSnapshot), through a read-only exception for that folder:
//  no app group, which a self-signed app can't have. Every button is a
//  nidus:// link, so Nidus itself decides, under the same rules as any link:
//  a strict session can't be ended from here.
//
//  SwiftPM doesn't build app extensions; Scripts/build-app.sh compiles this
//  with swiftc beside Core/WidgetSnapshot.swift.
//

import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Reading

enum WidgetFile {
    /// The real home folder: inside the sandbox, NSHomeDirectory() is the
    /// container's.
    static var url: URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Nidus", isDirectory: true)
            .appendingPathComponent(WidgetSnapshot.fileName)
    }

    static func read() -> WidgetSnapshot {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return WidgetSnapshot() }
        return snapshot
    }
}

struct NidusEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct NidusProvider: TimelineProvider {
    func placeholder(in context: Context) -> NidusEntry {
        NidusEntry(date: .now, snapshot: WidgetSnapshot(state: .focusing, goal: "Write the launch post",
                                                        endsAt: Date.now.addingTimeInterval(25 * 60).timeIntervalSince1970))
    }

    func getSnapshot(in context: Context, completion: @escaping (NidusEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : NidusEntry(date: .now, snapshot: WidgetFile.read()))
    }

    /// Nidus reloads the widget at every change; the one change it can't
    /// announce is time running out, so the timeline ends there.
    func getTimeline(in context: Context, completion: @escaping (Timeline<NidusEntry>) -> Void) {
        let snapshot = WidgetFile.read()
        var entries = [NidusEntry(date: .now, snapshot: snapshot)]
        if let end = snapshot.endDate, end > .now {
            var after = snapshot
            after.state = .idle
            after.endsAt = nil
            entries.append(NidusEntry(date: end, snapshot: after))
        }
        completion(Timeline(entries: entries, policy: .never))
    }
}

// MARK: - The widget

struct NidusWidgetView: View {
    let entry: NidusEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: WidgetSnapshot { entry.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            switch snapshot.state {
            case .idle: idle
            case .focusing, .paused, .onBreak: running
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
        // A small widget is one tap target (links inside it aren't followed):
        // the first setup when idle, else the popover.
        .widgetURL(family == .systemSmall ? smallURL : nil)
    }

    private var smallURL: URL {
        guard snapshot.state == .idle, let first = snapshot.setups.first else { return WidgetSnapshot.popoverURL }
        return WidgetSnapshot.startURL(setupID: first.id)
    }

    private var title: String {
        switch snapshot.state {
        case .idle: return "Nidus"
        case .focusing: return snapshot.strict ? "Focusing · strict" : "Focusing"
        case .paused: return "Paused"
        case .onBreak: return "Break"
        }
    }

    private var symbol: String {
        switch snapshot.state {
        case .idle: return "circle.dashed"
        case .focusing: return snapshot.strict ? "lock.fill" : "brain.head.profile"
        case .paused: return "pause.fill"
        case .onBreak: return "cup.and.saucer.fill"
        }
    }

    @ViewBuilder private var running: some View {
        Text(verbatim: snapshot.goal.isEmpty ? (snapshot.state == .onBreak ? "Next session soon" : "Focus") : snapshot.goal)
            .font(.headline)
            .lineLimit(family == .systemSmall ? 2 : 1)
        Spacer(minLength: 0)
        if let end = snapshot.endDate, snapshot.state != .paused {
            Text(end, style: .timer)
                .font(.system(.title, design: .rounded).monospacedDigit().weight(.medium))
            Text("until \(end, style: .time)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let left = snapshot.secondsLeft {
            Text(Duration.seconds(left), format: .time(pattern: .minuteSecond))
                .font(.system(.title, design: .rounded).monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
        } else {
            Text("Open-ended")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var idle: some View {
        if snapshot.setups.isEmpty {
            Spacer(minLength: 0)
            Link(destination: WidgetSnapshot.popoverURL) {
                Label("Start a session", systemImage: "play.fill")
                    .font(.subheadline.weight(.medium))
            }
        } else {
            // On a small widget only the first is started (the whole widget
            // is its button); the second is shown for what it is.
            let shown = Array(snapshot.setups.prefix(family == .systemSmall ? 2 : WidgetSnapshot.setupLimit))
            Spacer(minLength: 0)
            ForEach(shown) { setup in
                Link(destination: WidgetSnapshot.startURL(setupID: setup.id)) {
                    Label(setup.name, systemImage: setup.symbol)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.fill.secondary, in: .rect(cornerRadius: 8))
                }
            }
        }
    }
}

struct NidusStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "local.sam.nidus.status", provider: NidusProvider()) { entry in
            NidusWidgetView(entry: entry)
        }
        .configurationDisplayName("Nidus")
        .description("Your goal and time left, or a setup to start.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Control Center

struct StartNidusControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "local.sam.nidus.start") {
            let first = WidgetFile.read().setups.first
            ControlWidgetButton(action: OpenURLIntent(first.map { WidgetSnapshot.startURL(setupID: $0.id) }
                                                     ?? WidgetSnapshot.popoverURL)) {
                Label(first.map { "Start \($0.name)" } ?? "Start Nidus", systemImage: first?.symbol ?? "play.fill")
            }
        }
        .displayName("Start Nidus")
        .description("Starts your first setup, or opens Nidus when you have none.")
    }
}

struct EndNidusControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "local.sam.nidus.end") {
            ControlWidgetButton(action: OpenURLIntent(WidgetSnapshot.endURL)) {
                Label("End Nidus Session", systemImage: "stop.fill")
            }
        }
        .displayName("End Nidus Session")
        .description("Ends a session that isn't strict.")
    }
}

@main
struct NidusWidgets: WidgetBundle {
    var body: some Widget {
        NidusStatusWidget()
        StartNidusControl()
        EndNidusControl()
    }
}
