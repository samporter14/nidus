//
//  StrictGuard.swift
//  Nidus
//
//  What keeps a strict session from being quit away. While one runs, Nidus
//  refuses to quit (⌘Q from Activity Monitor, `kill`, an Apple Event), and a
//  small watcher run by launchd opens Nidus again if it crashes or is killed
//  outright. Both ask the same question of `session.json`: is a strict
//  session live? Nothing here runs between strict sessions.
//
//  Two ways out stay open on purpose: the Mac logging out, restarting or
//  shutting down, and an update. install.sh writes `update-quit` beside the
//  session before it asks Nidus to quit; a permit that fresh lets the quit
//  through, and the new copy picks the session up where it was.
//
//  Shared by the app, its watcher and the tests.
//

import Foundation

enum StrictGuard {
    /// The launchd job's label, and its plist in Contents/Library/LaunchAgents.
    static let agentLabel = "local.sam.nidus.keepalive"
    static var agentPlistName: String { agentLabel + ".plist" }
    /// While this file exists launchd keeps the watcher running (the job's
    /// KeepAlive PathState), so the app starts the watcher by making it and
    /// nothing has to run a command. A launchd plist can't name a home
    /// folder, so it is in /private/tmp, which a restart empties (Nidus,
    /// a login item, makes it again for a strict session it picks up).
    static let markerPath = "/private/tmp/local.sam.nidus.strict-session"
    /// The argument launchd starts the watcher with.
    static let watcherFlag = "--keepalive"
    /// Written by install.sh just before it quits Nidus for an update.
    static let updatePermitName = "update-quit"
    /// How long an update permit counts: install.sh quits Nidus straight after
    /// writing it, so an older one was left by an update that didn't finish.
    static let updatePermitLifetime: TimeInterval = 120

    /// A strict session that is on: running with time left, or paused only
    /// because the Mac slept or locked (a strict session can't be paused by
    /// hand). One whose deadline has passed ends at the next launch, so
    /// nothing is kept alive for it.
    static func isLiveStrict(_ session: SessionState?, now: Date) -> Bool {
        guard let session, session.plan.strict, session.endedAt == nil else { return false }
        switch session.phase {
        case .running(let deadline): return deadline > now
        case .paused(_, let bySleep): return bySleep
        }
    }

    /// The same, read from the saved file. An unreadable or missing file is
    /// not a strict session: the watcher must never keep Nidus up on a guess.
    static func isLiveStrict(record data: Data?, now: Date) -> Bool {
        guard let data, let record = try? JSONDecoder().decode(SessionRecord.self, from: data) else { return false }
        return isLiveStrict(record.session, now: now)
    }

    /// Whether quitting is refused. Logging out, restarting and shutting down
    /// always go through (holding them up would hold up the Mac), and so does
    /// an update with a fresh permit.
    static func vetoesQuit(liveStrict: Bool, systemIsEnding: Bool, updatePermitted: Bool) -> Bool {
        liveStrict && !systemIsEnding && !updatePermitted
    }

    /// Whether a permit written at `written` still counts at `now`.
    static func permitIsFresh(writtenAt written: Date?, now: Date) -> Bool {
        guard let written else { return false }
        let age = now.timeIntervalSince(written)
        return age >= -5 && age <= updatePermitLifetime
    }

    /// When the watcher opens Nidus again after it went: at once the first
    /// time, then backing off, so a copy that crashes as it opens is not
    /// opened in a tight loop. `recent` is how many times it was opened in
    /// the last few minutes.
    static func relaunchDelay(recent: Int) -> TimeInterval {
        recent <= 0 ? 1 : min(60, pow(2, Double(recent)))
    }
}
