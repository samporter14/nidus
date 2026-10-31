//
//  StrictKeepAlive.swift
//  Nidus
//
//  Strict sessions survive a crash and `kill -9`. Refusing to quit
//  (AppDelegate) covers ⌘Q, Activity Monitor's Quit and `kill`; a process
//  killed outright can't refuse, so a watcher opens Nidus again.
//
//  The watcher is Nidus itself, started by launchd as
//  `Nidus --keepalive` from Contents/Library/LaunchAgents (registered with
//  SMAppService the first time a strict session starts, which is when macOS
//  says a background item was added). It has no menu bar item and no
//  window. It runs only while `session.json` holds a live strict session:
//  launchd starts it at login and when a strict session starts, and it quits
//  as soon as there is none, so between strict sessions nothing runs.
//
//  While it runs it waits on the menu bar app's exit (no polling): when the
//  app goes and the strict session is still live, it opens Nidus again, at
//  once the first time and backing off after that. Killed itself, launchd
//  starts it again (KeepAlive on an unsuccessful exit).
//
//  To stop all of it from Terminal (README, "Strict sessions"):
//  launchctl bootout gui/$(id -u)/local.sam.nidus.keepalive
//

import AppKit
import Darwin
import OSLog
import ServiceManagement

// MARK: - The app's side

@MainActor
enum KeepAliveAgent {
    private static let log = Logger(subsystem: "local.sam.nidus", category: "keepalive")
    private static var service: SMAppService { SMAppService.agent(plistName: StrictGuard.agentPlistName) }

    /// Called when a strict session starts or resumes after a relaunch:
    /// makes sure the watcher is registered and running. Registering happens
    /// once (macOS then lists Nidus under Login Items, Allow in the
    /// Background); after that this only starts the job, which does nothing
    /// if it is running already.
    static func ensureWatching() {
        guard !Demo.isActive else { return }
        let service = service
        if service.status == .notRegistered || service.status == .notFound {
            do { try service.register() } catch {
                log.error("Couldn't register the strict-session watcher: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard service.status == .enabled else {
            log.notice("Strict-session watcher not enabled (\(String(describing: service.status), privacy: .public))")
            return
        }
        kickstart()
    }

    /// Whether the watcher can run: registered and allowed in Login Items.
    static var isAvailable: Bool { !Demo.isActive && service.status == .enabled }

    /// `launchctl kickstart` starts a loaded job that isn't running; one that
    /// is running is left as it is.
    private static func kickstart() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "gui/\(getuid())/\(StrictGuard.agentLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            log.error("Couldn't start the strict-session watcher: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Update permit

/// The file install.sh writes before quitting Nidus for an update.
enum UpdatePermit {
    static func url(in directory: URL) -> URL { directory.appendingPathComponent(StrictGuard.updatePermitName) }

    static func isFresh(in directory: URL, now: Date = Date()) -> Bool {
        let written = (try? FileManager.default.attributesOfItem(atPath: url(in: directory).path))?[.modificationDate] as? Date
        return StrictGuard.permitIsFresh(writtenAt: written, now: now)
    }

    static func clear(in directory: URL) {
        try? FileManager.default.removeItem(at: url(in: directory))
    }
}

// MARK: - The watcher

/// `Nidus --keepalive`, as launchd runs it. Never returns.
@MainActor
enum KeepAliveWatcher {
    private static let log = Logger(subsystem: "local.sam.nidus", category: "keepalive")
    private static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Nidus", isDirectory: true)
    private static var exitSource: DispatchSourceProcess?
    private static var relaunches: [Date] = []
    private static var relaunchPending = false
    private static var focusObserver: NSObjectProtocol?

    static func run() -> Never {
        guard isLive() else { exit(0) }
        // launchd's own SIGTERM (logout, or bootout) still ends this with
        // SIGKILL after ExitTimeOut; a plain `kill` doesn't.
        signal(SIGTERM, SIG_IGN)
        log.info("Watching a strict session")
        // The app says so on every session change; when the strict session
        // is over there is nothing to watch.
        focusObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.sam.nidus.focus"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { exitIfDone() }
        }
        if let pid = runningAppPID() {
            watch(pid)
        } else {
            scheduleRelaunch()
        }
        RunLoop.main.run()
        exit(0)
    }

    private static func isLive() -> Bool {
        StrictGuard.isLiveStrict(record: try? Data(contentsOf: directory.appendingPathComponent("session.json")),
                                 now: Date())
    }

    private static func exitIfDone() {
        guard !isLive() else { return }
        log.info("Strict session over; watcher done")
        exit(0)
    }

    /// The menu bar app: another process running this same executable.
    private static func runningAppPID() -> pid_t? {
        guard let me = Bundle.main.executableURL?.resolvingSymlinksInPath().path else { return nil }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 16)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let own = getpid()
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(Int(max(0, found))) where pid > 0 && pid != own {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard path == me else { continue }
            // Another watcher (it shouldn't be, launchd runs one) is not the app.
            if isWatcher(pid) { continue }
            return pid
        }
        return nil
    }

    private static func isWatcher(_ pid: pid_t) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return false }
        let flag = Array(StrictGuard.watcherFlag.utf8)
        return bytes.prefix(size).split(separator: 0).contains { Array($0) == flag }
    }

    private static func watch(_ pid: pid_t) {
        exitSource?.cancel()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { appWent() }
        }
        source.resume()
        exitSource = source
    }

    private static func appWent() {
        exitSource?.cancel()
        exitSource = nil
        exitIfDone()
        if UpdatePermit.isFresh(in: directory) {
            // install.sh is putting a new copy in place and opens it itself.
            // Look again once it has had time to.
            log.info("Nidus quit for an update; waiting for the new copy")
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                MainActor.assumeIsolated {
                    exitIfDone()
                    if let pid = runningAppPID() { watch(pid) } else { scheduleRelaunch() }
                }
            }
            return
        }
        scheduleRelaunch()
    }

    private static func scheduleRelaunch() {
        guard !relaunchPending else { return }
        relaunchPending = true
        relaunches.removeAll { $0.timeIntervalSinceNow < -300 }
        let delay = StrictGuard.relaunchDelay(recent: relaunches.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { relaunch() }
        }
    }

    private static func relaunch() {
        relaunchPending = false
        exitIfDone()
        if let pid = runningAppPID() { return watch(pid) }
        relaunches.append(Date())
        log.notice("Nidus went during a strict session; opening it again")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, error in
            let pid = app?.processIdentifier
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let pid, pid > 0 { watch(pid) } else {
                        log.error("Couldn't open Nidus: \(error?.localizedDescription ?? "unknown", privacy: .public)")
                        scheduleRelaunch()
                    }
                }
            }
        }
    }
}

// MARK: - The model's side

extension NidusModel {
    var containerDirectory: URL? { host?.environment.containerDirectory }

    /// A strict session is on (StrictGuard.isLiveStrict).
    var isStrictSessionLive: Bool { StrictGuard.isLiveStrict(engine?.session, now: Date()) }

    /// Starts the watcher for a strict session, at its start and when one is
    /// picked up after a relaunch. Anything else leaves it alone: it quits by
    /// itself when the strict session is over.
    func keepStrictSessionAlive() {
        guard !Demo.isActive, isStrictSessionLive else { return }
        KeepAliveAgent.ensureWatching()
    }
}
