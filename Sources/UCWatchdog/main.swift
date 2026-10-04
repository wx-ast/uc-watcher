import Foundation
import Darwin
import AppKit

let label = "local.uc-watchdog"
let ucPath = "/System/Library/CoreServices/UniversalControl.app/Contents/MacOS/UniversalControl"
let sharingPath = "/usr/libexec/sharingd"
let predicate = "subsystem == \"com.apple.universalcontrol\""

enum WatchError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let value) = self { return value }; return "Error" }
}

final class Logger {
    let directory: URL
    let echo: Bool
    let lock = NSLock()
    let formatter = ISO8601DateFormatter()
    init(_ directory: URL, echo: Bool = true) throws {
        self.directory = directory; self.echo = echo
        formatter.timeZone = .current
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    func write(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) \(message)\n"
        if echo { FileHandle.standardError.write(Data(line.utf8)) }
        let file = directory.appendingPathComponent("watchdog.log")
        do {
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            if size >= 1_000_000 {
                for index in stride(from: 3, through: 1, by: -1) {
                    let destination = directory.appendingPathComponent("watchdog.log.\(index)")
                    let source = index == 1 ? file : directory.appendingPathComponent("watchdog.log.\(index - 1)")
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.moveItem(at: source, to: destination) }
                }
            }
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: Data(line.utf8))
        } catch {
            FileHandle.standardError.write(Data("Logging error: \(error)\n".utf8))
        }
    }
}

final class Guard {
    let peer: String
    let history: URL?
    let log: (String) -> Void
    let recovery: () throws -> Void
    let recovered: (RecoveryIncident) -> Void
    let recoveryEnabled: Bool
    var pendingIncident: RecoveryIncident?
    var attempts: [Double] = []
    var lastAttempt: Double = -.infinity
    var handledLoss = false
    init(peer: String, history: URL? = nil, log: @escaping (String) -> Void,
         recovered: @escaping (RecoveryIncident) -> Void = { _ in }, recoveryEnabled: Bool = true,
         recovery: @escaping () throws -> Void) {
        self.peer = peer; self.history = history; self.log = log; self.recovery = recovery; self.recovered = recovered
        self.recoveryEnabled = recoveryEnabled
        if let path = history, let data = try? Data(contentsOf: path),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let stored = value["attempts"] as? [Double] {
            attempts = stored.filter { $0.isFinite }
            lastAttempt = attempts.max() ?? -.infinity
            if (value["peer"] as? String ?? peer) == peer,
               let incident = value["pendingIncident"], let data = try? JSONSerialization.data(withJSONObject: incident) {
                pendingIncident = try? JSONDecoder().decode(RecoveryIncident.self, from: data)
            }
        }
    }
    func saveHistory() throws {
        guard let path = history else { return }
        var value: [String: Any] = ["attempts": attempts, "peer": peer]
        if let incident = pendingIncident {
            value["pendingIncident"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(incident))
        }
        try JSONSerialization.data(withJSONObject: value).write(to: path, options: .atomic)
    }
    func event(_ message: String, now: Double) {
        guard message.contains("IDS \(peer):") else { return }
        if message.contains("IDS \(peer): Connected"), var incident = pendingIncident {
            incident.restoredAt = now
            recovered(incident)
            pendingIncident = nil
            do { try saveHistory() } catch { log("Cannot save incident completion: \(error)") }
            log("Input connection restored after \(Int(max(0, now - incident.startedAt)))s")
        } else if message.contains("Device Found") || message.contains("Device Available") {
            handledLoss = false
            log("Peer discovered: \(message)")
        } else if message.contains("Device Lost") {
            log("BLE discovery lost; waiting for confirmed unavailability")
        } else if message.contains("Device Unavailable") {
            log("Peer unavailable: \(message)")
            if pendingIncident == nil {
                pendingIncident = RecoveryIncident(startedAt: now, restartAttempted: false)
                do { try saveHistory() } catch { log("Cannot save incident: \(error)") }
            }
            guard !handledLoss else { return }
            handledLoss = true
            attempts.removeAll { now - $0 >= 600 }
            guard now - lastAttempt >= 120 else { log("Recovery suppressed: cooldown 120s"); return }
            guard attempts.count < 3 else { log("Recovery suppressed: limit 3 per 600s"); return }
            lastAttempt = now; attempts.append(now)
            if recoveryEnabled { pendingIncident?.restartAttempted = true }
            do {
                try saveHistory()
                try recovery()
            } catch { log("Recovery failed: \(error)") }
        }
    }
}

func command(_ path: String, _ arguments: [String], allowFailure: Bool = false) throws -> String {
    let process = Process(); let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
    process.standardOutput = pipe; process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(data: data, encoding: .utf8) ?? ""
    if process.terminationStatus != 0 && !allowFailure {
        throw WatchError.message("\(path) exited \(process.terminationStatus): \(output)")
    }
    return output
}

func parseProcesses(_ output: String, executable: String, uid: uid_t) -> [pid_t] {
    output.split(separator: "\n").compactMap { line in
        let fields = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count == 3, UInt32(fields[1]) == uid,
              fields[2].trimmingCharacters(in: .whitespaces) == executable else { return nil }
        return Int32(fields[0])
    }
}

func ownProcesses(_ executable: String) throws -> [pid_t] {
    parseProcesses(try command("/bin/ps", ["-axo", "pid=,uid=,comm="]), executable: executable, uid: getuid())
}

func recover(_ logger: Logger, dryRun: Bool) throws {
    for (executable, sig) in [(sharingPath, SIGTERM), (ucPath, SIGKILL)] {
        let pids = try ownProcesses(executable)
        if pids.isEmpty { logger.write("Process absent: \(executable)") }
        for pid in pids {
            guard try ownProcesses(executable).contains(pid) else { continue }
            if dryRun { logger.write("DRY RUN: would signal \(executable) pid=\(pid) signal=\(sig)") }
            else if kill(pid, sig) == 0 { logger.write("Recovery: signaled \(executable) pid=\(pid) signal=\(sig)") }
            else if errno != ESRCH { throw WatchError.message("kill(\(pid)): \(String(cString: strerror(errno)))") }
        }
    }
}

func option(_ name: String, default fallback: String, in arguments: [String]) -> String {
    if let position = arguments.firstIndex(of: name), position + 1 < arguments.count { return arguments[position + 1] }
    return fallback
}

func validatePeer(_ peer: String) throws {
    guard !peer.isEmpty, peer.allSatisfy({ "0123456789ABCDEF-".contains($0) }) else {
        throw WatchError.message("--peer must be a hexadecimal IDS prefix")
    }
}

func monitor(_ arguments: [String]) throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let state = URL(fileURLWithPath: NSString(string: option("--state-dir", default: home.appendingPathComponent("Library/Logs/UCWatchdog").path, in: arguments)).expandingTildeInPath)
    let peer = option("--peer", default: "3047DD83", in: arguments).uppercased()
    try validatePeer(peer)
    let dryRun = arguments.contains("--dry-run")
    let logger = try Logger(state, echo: !arguments.contains("--service"))
    let lockFD = open(state.appendingPathComponent("watchdog.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
    guard lockFD >= 0 else { throw WatchError.message("Cannot open watchdog lock") }
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
        close(lockFD); throw WatchError.message("A watchdog is already running for this user")
    }
    NSApplication.shared.setActivationPolicy(.accessory)
    let notice = RecoveryNotice(logger: logger, enabled: !dryRun)
    if !dryRun { notice.authorize() }
    let guardState = Guard(peer: peer, history: state.appendingPathComponent("recovery-history.json"), log: logger.write,
                          recovered: { incident in
        DispatchQueue.main.sync { notice.recovered(incident) }
    }, recoveryEnabled: !dryRun) {
        try recover(logger, dryRun: dryRun)
    }
    let process = Process(); let pipe = Pipe()
    let processing = DispatchQueue(label: "local.uc-watchdog.events")
    var pending = Data(); var records = 0
    process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    process.arguments = ["stream", "--style", "ndjson", "--info", "--predicate", predicate]
    process.standardOutput = pipe; process.standardError = pipe
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { handle.readabilityHandler = nil; return }
        processing.async {
            pending.append(data)
            while let end = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: end)
                pending.removeSubrange(...end)
                if let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   let message = record["eventMessage"] as? String {
                    records += 1
                    if records == 1 { logger.write("Live Universal Control events are readable") }
                    guardState.event(message, now: Date().timeIntervalSince1970)
                } else if let text = String(data: line, encoding: .utf8), !text.isEmpty {
                    logger.write("log stream: \(text.prefix(1000))")
                }
            }
            if pending.count > 1_000_000 { logger.write("Oversized log record; stopping monitor"); process.terminate() }
        }
    }
    process.terminationHandler = { finished in
        logger.write("log stream exited \(finished.terminationStatus); launchd will retry")
        exit(1)
    }
    logger.write("Starting native Swift watchdog peer=\(peer) dryRun=\(dryRun); cooldown=120s max=3/600s")
    try process.run()
    let stop: () -> Void = {
        pipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        process.terminate()
        logger.write("Watchdog stopped")
        close(lockFD)
        exit(0)
    }
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    term.setEventHandler(handler: stop); interrupt.setEventHandler(handler: stop)
    term.resume(); interrupt.resume()
    let duration = Double(option("--duration", default: "0", in: arguments)) ?? 0
    if duration > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: stop) }
    let parent = Int32(option("--parent-pid", default: "0", in: arguments)) ?? 0
    let parentCheck: Timer? = parent > 1 ? Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        if getppid() != parent { stop() }
    } : nil
    withExtendedLifetime((term, interrupt, notice, parentCheck)) { NSApplication.shared.run() }
}

func makeBundle(at bundle: URL) throws {
    let fm = FileManager.default
    // A distributed app must retain its signature, resources and stapled ticket.
    // Rebuilding it here would replace Developer ID with an ad-hoc signature.
    let runningBundle = Bundle.main.bundleURL
    if runningBundle.pathExtension == "app", Bundle.main.bundleIdentifier == label {
        _ = try command("/usr/bin/codesign", ["--verify", "--strict", runningBundle.path])
        try fm.copyItem(at: runningBundle, to: bundle)
        _ = try command("/usr/bin/codesign", ["--verify", "--strict", bundle.path])
        return
    }
    let contents = bundle.appendingPathComponent("Contents")
    let executable = contents.appendingPathComponent("MacOS/uc-watchdog")
    try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    let source = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
    try fm.copyItem(at: source, to: executable)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let resources = contents.appendingPathComponent("Resources")
    try fm.createDirectory(at: resources, withIntermediateDirectories: true)
    // Installed apps carry their own icon; SwiftPM builds use the adjacent resource bundle.
    guard let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        ?? Bundle.module.url(forResource: "AppIcon", withExtension: "icns") else {
        throw WatchError.message("AppIcon.icns is missing from the application resources")
    }
    try fm.copyItem(at: icon, to: resources.appendingPathComponent("AppIcon.icns"))
    let info: [String: Any] = ["CFBundleIdentifier": label, "CFBundleName": "UC Watchdog",
                              "CFBundleDisplayName": "UC Watchdog", "CFBundleExecutable": "uc-watchdog",
                              "CFBundleIconFile": "AppIcon.icns",
                              "CFBundlePackageType": "APPL", "CFBundleVersion": "9",
                              "CFBundleShortVersionString": "1.0", "LSMinimumSystemVersion": "13.0",
                              "UCWatchdogAuthor": "wx-ast",
                              "UCWatchdogSourceURL": "https://github.com/wx-ast/uc-watcher",
                              "LSUIElement": true]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
    // Stable requirement keeps the notification identity across local rebuilds.
    _ = try command("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", label,
                                         "--requirements", "=designated => identifier \"\(label)\"", bundle.path])
}

func bundleCommand(_ arguments: [String]) throws {
    let destination = URL(fileURLWithPath: option("--output", default: ".build/UC Watchdog.app", in: arguments)).standardizedFileURL
    guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw WatchError.message("Bundle destination already exists: \(destination.path)")
    }
    try makeBundle(at: destination)
    print(destination.path)
}

func stopInstalledProcesses(_ binary: URL) throws {
    let pids = try ownProcesses(binary.path).filter { $0 != getpid() }
    for pid in pids {
        guard try ownProcesses(binary.path).contains(pid) else { continue }
        guard kill(pid, SIGTERM) == 0 || errno == ESRCH else {
            throw WatchError.message("Cannot stop UC Watchdog pid=\(pid)")
        }
    }
    for delay in [0.05, 0.1, 0.2, 0.5, 1.0, 2.0] {
        if Set(try ownProcesses(binary.path)).isDisjoint(with: pids) { return }
        Thread.sleep(forTimeInterval: delay)
    }
    guard Set(try ownProcesses(binary.path)).isDisjoint(with: pids) else {
        throw WatchError.message("UC Watchdog has not stopped; installed files retained")
    }
}

func manage(_ action: String, _ arguments: [String]) throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let app = home.appendingPathComponent("Library/Application Support/UCWatchdog")
    let bundle = installedApplicationURL()
    let binary = bundle.appendingPathComponent("Contents/MacOS/uc-watchdog")
    let legacyBinary = app.appendingPathComponent("uc-watchdog")
    let logs = defaultStateDirectory()
    let plist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    let domain = "gui/\(getuid())"
    let fm = FileManager.default
    if action == "status" {
        if Bundle.main.bundleURL.standardizedFileURL == bundle.standardizedFileURL {
            print("Autostart: \(autostartStatus())")
        } else if fm.fileExists(atPath: binary.path) {
            print(try command(binary.path, ["autostart", "status"]))
        }
        print("UC Watchdog processes: \(try ownProcesses(binary.path).filter { $0 != getpid() })")
        print("Log: \(logs.appendingPathComponent("watchdog.log").path)")
        return
    }
    if action == "uninstall" {
        if fm.fileExists(atPath: binary.path) {
            if Bundle.main.bundleURL.standardizedFileURL == bundle.standardizedFileURL {
                try setAutostart(false)
            } else {
                _ = try command(binary.path, ["autostart", "off"])
            }
        }
        _ = try command("/bin/launchctl", ["bootout", "\(domain)/\(label)"], allowFailure: true)
        try stopInstalledProcesses(binary)
        for file in [plist, bundle, legacyBinary] where fm.fileExists(atPath: file.path) {
            try fm.removeItem(at: file)
        }
        print("Uninstalled; existing diagnostic logs retained at \(logs.path)")
        return
    }
    let stored = try WatchConfiguration.load(from: logs)
    let configured = fm.fileExists(atPath: logs.appendingPathComponent("configuration.json").path)
    guard arguments.contains("--peer") || configured else {
        throw WatchError.message("Choose a device in the app, or run peers and install --peer <prefix>")
    }
    if let index = arguments.firstIndex(of: "--peer"),
       index + 1 >= arguments.count || arguments[index + 1].hasPrefix("--") {
        throw WatchError.message("--peer requires a prefix; use peers to list devices")
    }
    let peer = option("--peer", default: stored.peer, in: arguments).uppercased()
    try validatePeer(peer)
    var loginEnabled = true
    if fm.fileExists(atPath: binary.path), !fm.fileExists(atPath: plist.path) {
        let previous = try command(binary.path, ["autostart", "status"], allowFailure: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        loginEnabled = previous != "disabled"
    }
    try fm.createDirectory(at: app, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fm.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let stage = app.appendingPathComponent("UC Watchdog-\(UUID().uuidString).app")
    defer { try? fm.removeItem(at: stage) }
    try makeBundle(at: stage)
    // Unregister the old application before replacing it, and migrate the legacy LaunchAgent.
    if fm.fileExists(atPath: binary.path) { _ = try command(binary.path, ["autostart", "off"]) }
    _ = try command("/bin/launchctl", ["bootout", "\(domain)/\(label)"], allowFailure: true)
    try stopInstalledProcesses(binary)
    if fm.fileExists(atPath: bundle.path) {
        _ = try fm.replaceItemAt(bundle, withItemAt: stage)
    } else {
        try fm.moveItem(at: stage, to: bundle)
    }
    for file in [plist, legacyBinary, app.appendingPathComponent("watchdog.py"), app.appendingPathComponent("install.py")]
        where fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
    let historyFile = logs.appendingPathComponent("recovery-history.json")
    if configured, stored.peer != peer, let data = try? Data(contentsOf: historyFile),
       var history = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], history["peer"] == nil {
        // Bind legacy pending incidents to their original Mac when changing the selection.
        history["peer"] = stored.peer
        try JSONSerialization.data(withJSONObject: history).write(to: historyFile, options: .atomic)
    }
    try WatchConfiguration(peer: peer, dryRun: arguments.contains("--dry-run")).save(to: logs)
    _ = try command("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", bundle.path])
    if loginEnabled { print(try command(binary.path, ["autostart", "on"])) }
    // A distributed copy may still be running with the same bundle ID.
    // Force opening the installed path; the menu lock prevents duplicate instances.
    try openInstalledApplication()
    print("Installed UC Watchdog menu bar app; mode: \(arguments.contains("--dry-run") ? "observation" : "automatic recovery")")
    print("Log: \(logs.appendingPathComponent("watchdog.log").path)")
}

func selfTest() throws {
    try installationLaunchSelfTest()
    var calls = 0
    let guardState = Guard(peer: "3047DD83", log: { _ in }) { calls += 1 }
    func event(_ kind: String, _ now: Double) { guardState.event("IDS 3047DD83: \(kind)", now: now) }
    event("Device Lost", 0); event("Device Found", 30)
    guardState.event("IDS FFFFFFFF: Device Unavailable", now: 40)
    guard calls == 0 else { throw WatchError.message("Short loss/peer filter failed") }
    event("Device Unavailable", 100); event("Device Unavailable", 101)
    guard calls == 1 else { throw WatchError.message("Duplicate loss failed") }
    event("Device Available", 110); event("Device Unavailable", 120)
    guard calls == 1 else { throw WatchError.message("Cooldown failed") }
    for time in [220.0, 340.0, 460.0] { event("Device Available", time); event("Device Unavailable", time) }
    guard calls == 3 else { throw WatchError.message("Window limit failed") }
    event("Device Available", 700); event("Device Unavailable", 700)
    guard calls == 4 else { throw WatchError.message("Window expiration failed") }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let history = directory.appendingPathComponent("history.json")
    let first = Guard(peer: "3047DD83", history: history, log: { _ in }) { calls += 1 }
    first.event("IDS 3047DD83: Device Unavailable", now: 1000)
    let second = Guard(peer: "3047DD83", history: history, log: { _ in }) { calls += 1 }
    second.event("IDS 3047DD83: Device Unavailable", now: 1050)
    guard calls == 5 else { throw WatchError.message("Persistent cooldown failed") }
    let rows = "123 502 \(ucPath)\n124 501 \(ucPath)\n125 502 /simulator\(ucPath)\n"
    guard parseProcesses(rows, executable: ucPath, uid: 502) == [123] else {
        throw WatchError.message("Process ownership/path filter failed")
    }
    let failed = Guard(peer: "3047DD83", log: { _ in }) { throw WatchError.message("Test failure") }
    failed.event("IDS 3047DD83: Device Unavailable", now: 100)
    guard failed.attempts.count == 1 && failed.handledLoss else { throw WatchError.message("Failure rate limit failed") }
    var notices: [RecoveryIncident] = []
    let notifying = Guard(peer: "3047DD83", log: { _ in }, recovered: { notices.append($0) }) {}
    notifying.event("IDS 3047DD83: Device Unavailable", now: 2000)
    notifying.event("IDS 3047DD83: Device Available", now: 2002)
    guard notices.isEmpty else { throw WatchError.message("Discovery is not confirmed restoration") }
    notifying.event("IDS FFFFFFFF: Connected", now: 2003)
    guard notices.isEmpty else { throw WatchError.message("Other peer restoration filter failed") }
    notifying.event("IDS 3047DD83: Connected", now: 2027)
    notifying.event("IDS 3047DD83: Connected", now: 2028)
    guard notices.count == 1, notices[0].restoredAt == 2027, notices[0].restartAttempted else {
        throw WatchError.message("Confirmed restoration notification failed")
    }
    // Incident tracking also survives a monitor restart and rate-limited recovery.
    var restoredAfterRestart: [RecoveryIncident] = []
    let third = Guard(peer: "3047DD83", history: history, log: { _ in }, recovered: { restoredAfterRestart.append($0) }) {}
    third.event("IDS 3047DD83: Connected", now: 1060)
    guard restoredAfterRestart.count == 1, restoredAfterRestart[0].startedAt == 1000 else {
        throw WatchError.message("Pending incident persistence failed")
    }
    guard RecoveryNotice.content(for: RecoveryIncident(startedAt: 2000, restartAttempted: true)) == nil else {
        throw WatchError.message("Unconfirmed restoration must not produce notification content")
    }
    guard let content = RecoveryNotice.content(for: notices[0], language: .russian), content.title == "Связь восстановлена",
          content.body.contains("27 с"), content.body.contains("Watchdog запускал восстановление."),
          RecoveryNotice.content(for: notices[0], preview: true, language: .russian)?.title == "Проверка уведомления" else {
        throw WatchError.message("Native notification content failed")
    }
    guard AppLanguage.resolve(nil) == .english, AppLanguage.resolve("unsupported") == .english,
          AppLanguage.resolve("ru") == .russian,
          let english = RecoveryNotice.content(for: notices[0], language: .english),
          english.title == "Connection Restored", english.body.contains("27 s."),
          english.body.contains("Watchdog attempted recovery."),
          RecoveryNotice.content(for: notices[0], preview: true, language: .english)?.title == "Notification Test",
          let automatic = RecoveryNotice.content(for: RecoveryIncident(startedAt: 2000, restoredAt: 2027,
                                                                        restartAttempted: false), language: .english),
          automatic.body.contains("without a watchdog restart") else {
        throw WatchError.message("Language fallback/English notification content failed")
    }
    if Bundle.main.bundleIdentifier == label {
        guard AppLanguage.preferences === UserDefaults.standard else {
            throw WatchError.message("Bundled application must use its standard language preferences")
        }
    }
    let configuration = WatchConfiguration(peer: "3047DD83", dryRun: true)
    try configuration.save(to: directory)
    guard try WatchConfiguration.load(from: directory) == configuration else {
        throw WatchError.message("Menu configuration persistence failed")
    }
    let configFile = directory.appendingPathComponent("configuration.json")
    try Data("{\"peer\":\"invalid\",\"dryRun\":false}".utf8).write(to: configFile)
    var invalidRejected = false
    do { _ = try WatchConfiguration.load(from: directory) } catch { invalidRejected = true }
    guard invalidRejected else { throw WatchError.message("Invalid menu configuration accepted") }
    var policy = MonitorRestartPolicy()
    let now = Date(timeIntervalSince1970: 1000)
    guard !policy.shouldStart(running: false, now: now) else { throw WatchError.message("Stopped monitor started") }
    policy.start(); policy.failed(at: now)
    guard !policy.shouldStart(running: false, now: now.addingTimeInterval(29)),
          policy.shouldStart(running: false, now: now.addingTimeInterval(30)),
          !policy.shouldStart(running: true, now: now.addingTimeInterval(30)) else {
        throw WatchError.message("Monitor restart throttling failed")
    }
    policy.stop()
    guard !policy.shouldStart(running: false, now: now.addingTimeInterval(60)) else {
        throw WatchError.message("Stopped monitor retried")
    }
    try peerDiscoverySelfTest()
    let changedHistory = directory.appendingPathComponent("peer-history.json")
    let originalPeer = Guard(peer: "3047DD83", history: changedHistory, log: { _ in }) {}
    originalPeer.event("IDS 3047DD83: Device Unavailable", now: 2000)
    let changedPeer = Guard(peer: "AAAAAAAA", history: changedHistory, log: { _ in }) {}
    guard originalPeer.pendingIncident != nil, changedPeer.pendingIncident == nil,
          changedPeer.lastAttempt == originalPeer.lastAttempt else {
        throw WatchError.message("Peer change must preserve rate limits without inheriting another Mac's incident")
    }
    print("Self-tests passed, including installation launch races; no service signals sent")
}

func previewNotification(_ arguments: [String]) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let logger = try Logger(directory)
    NSApplication.shared.setActivationPolicy(.accessory)
    let notice = RecoveryNotice(logger: logger)
    guard let center = notice.center else {
        try? FileManager.default.removeItem(at: directory)
        throw WatchError.message("Use preview-notification from the bundled executable (see bundle/install)")
    }
    notice.preview = true
    center.requestAuthorization(options: [.alert]) { granted, error in
        if let error { logger.write("Notification authorization failed: \(error)"); exit(1) }
        guard granted else { logger.write("Enable UC Watchdog in System Settings > Notifications"); exit(1) }
        DispatchQueue.main.async {
            let now = Date().timeIntervalSince1970
            notice.recovered(RecoveryIncident(startedAt: now - 27, restoredAt: now, restartAttempted: true))
            let duration = Double(option("--duration", default: "10", in: arguments)) ?? 10
            DispatchQueue.main.asyncAfter(deadline: .now() + max(1, duration)) {
                try? FileManager.default.removeItem(at: directory)
                exit(0)
            }
        }
    }
    withExtendedLifetime(notice) { NSApplication.shared.run() }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first ?? (Bundle.main.bundleURL.pathExtension == "app" ? "launch" : "help") {
    case "launch": try launchApplication()
    case "monitor": try monitor(arguments)
    case "peers":
        let peers = try discoverPeers()
        if peers.isEmpty { print("No Universal Control devices found in the last 24 hours") }
        for peer in peers { print("\(peer.title)  last seen: \(peer.lastSeen)") }
    case "menu": try menuBar(arguments)
    case "menu-self-test": try menuSelfTest()
    case "autostart":
        try requireApplicationBundle()
        switch arguments.dropFirst().first ?? "status" {
        case "on": try setAutostart(true)
        case "off": try setAutostart(false)
        case "status": break
        default: throw WatchError.message("autostart expects on|off|status")
        }
        print(autostartStatus())
    case "install", "uninstall", "status": try manage(arguments[0], arguments)
    case "self-test": try selfTest()
    case "bundle": try bundleCommand(arguments)
    case "preview-notification": try previewNotification(arguments)
    case "check-processes":
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("uc-watchdog-check")
        try recover(Logger(directory), dryRun: true)
    default:
        print("uc-watchdog monitor|peers|install|uninstall|status|menu|autostart|self-test|check-processes|bundle|preview-notification [--peer PREFIX] [--dry-run]")
    }
} catch {
    FileHandle.standardError.write(Data("uc-watchdog: \(error)\n".utf8)); exit(1)
}
