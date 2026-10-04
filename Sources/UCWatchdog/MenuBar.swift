import AppKit
import ServiceManagement
import Darwin

struct WatchConfiguration: Codable, Equatable {
    var peer = "3047DD83"
    var dryRun = false

    static func load(from directory: URL) throws -> WatchConfiguration {
        let file = directory.appendingPathComponent("configuration.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return WatchConfiguration() }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        try validatePeer(value.peer)
        return value
    }

    func save(to directory: URL) throws {
        try validatePeer(peer)
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("configuration.json"), options: .atomic)
    }
}

func defaultStateDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/UCWatchdog")
}

func installedApplicationURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/UCWatchdog/UC Watchdog.app")
}

func launchApplication(confirm: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }) throws {
    try requireApplicationBundle()
    let installed = installedApplicationURL()
    if Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        == installed.standardizedFileURL.resolvingSymlinksInPath() {
        try menuBar([])
        return
    }
    NSApplication.shared.setActivationPolicy(.accessory)
    let exists = FileManager.default.fileExists(atPath: installed.path)
    let alert = NSAlert()
    alert.messageText = exists ? localized("Universal Control Watcher is already installed", "Universal Control Watcher уже установлен") : localized("Install Universal Control Watcher?", "Установить Universal Control Watcher?")
    alert.informativeText = exists
        ? localized("Open the installed application or replace it with this copy. History and logs will be retained.", "Можно открыть установленное приложение или заменить его этой копией. История и журналы сохранятся.")
        : localized("The application will be installed for the current user and started. You can disable launch at login in the menu.", "Приложение будет установлено для текущего пользователя и запущено. Автозапуск при входе можно отключить в меню.")
    alert.addButton(withTitle: exists ? localized("Open Installed App", "Открыть установленное") : localized("Install", "Установить"))
    if exists { alert.addButton(withTitle: localized("Update", "Обновить")) }
    alert.addButton(withTitle: localized("Cancel", "Отмена"))
    NSApplication.shared.activate(ignoringOtherApps: true)
    let response = confirm(alert)
    do {
        if exists && response == .alertFirstButtonReturn {
            _ = try command("/usr/bin/open", ["-n", installed.path])
        } else if (!exists && response == .alertFirstButtonReturn) || (exists && response == .alertSecondButtonReturn) {
            var arguments: [String] = []
            if exists {
                let configuration = try WatchConfiguration.load(from: defaultStateDirectory())
                arguments = ["--peer", configuration.peer]
                if configuration.dryRun { arguments.append("--dry-run") }
            } else {
                guard let peer = try choosePeer() else { return }
                arguments = ["--peer", peer]
            }
            try manage("install", arguments)
        }
    } catch {
        let failure = NSAlert()
        failure.messageText = localized("Could not start the application", "Не удалось запустить приложение")
        failure.informativeText = String(describing: error)
        failure.runModal()
        throw error
    }
}

func requireApplicationBundle() throws {
    guard Bundle.main.bundleIdentifier == label, Bundle.main.bundleURL.pathExtension == "app" else {
        throw WatchError.message("This command must run from UC Watchdog.app")
    }
}

func autostartStatus() -> String {
    switch SMAppService.mainApp.status {
    case .enabled: return "enabled"
    case .notRegistered: return "disabled"
    case .requiresApproval: return "requires approval in System Settings"
    case .notFound: return "application not found"
    @unknown default: return "unknown"
    }
}

func setAutostart(_ enabled: Bool) throws {
    try requireApplicationBundle()
    let service = SMAppService.mainApp
    if enabled {
        if service.status == .notRegistered || service.status == .notFound { try service.register() }
    } else if service.status != .notRegistered {
        try service.unregister()
    }
}

// A stopped monitor stays stopped; unexpected exits are retried no sooner than 30 seconds.
struct MonitorRestartPolicy {
    var wanted = false
    var nextStart: Date = .distantPast
    mutating func start() { wanted = true; nextStart = .distantPast }
    mutating func stop() { wanted = false }
    mutating func failed(at now: Date) { nextStart = now.addingTimeInterval(30) }
    func shouldStart(running: Bool, now: Date) -> Bool { wanted && !running && now >= nextStart }
}

final class MonitorSupervisor {
    let directory: URL
    let configuration: WatchConfiguration
    let logger: Logger
    var process: Process?
    var policy = MonitorRestartPolicy()
    var isRunning: Bool { process?.isRunning == true }

    init(directory: URL, configuration: WatchConfiguration, logger: Logger) {
        self.directory = directory; self.configuration = configuration; self.logger = logger
    }

    func start() { policy.start(); tick() }
    func stop() {
        policy.stop()
        guard let child = process else { return }
        child.terminationHandler = nil
        if child.isRunning { child.terminate(); child.waitUntilExit() }
        process = nil
    }

    func tick() {
        guard policy.shouldStart(running: isRunning, now: Date()) else { return }
        let child = Process()
        child.executableURL = Bundle.main.executableURL
        child.arguments = ["monitor", "--peer", configuration.peer, "--state-dir", directory.path,
                           "--service", "--parent-pid", String(getpid())]
        if configuration.dryRun { child.arguments?.append("--dry-run") }
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.process === finished else { return }
                self.process = nil
                self.policy.failed(at: Date())
                self.logger.write("Monitor exited \(finished.terminationStatus); retry in 30s")
            }
        }
        do {
            try child.run()
            process = child
            logger.write("Menu started monitor pid=\(child.processIdentifier)")
        } catch {
            policy.failed(at: Date())
            logger.write("Cannot start monitor: \(error); retry in 30s")
        }
    }
}

final class MenuBarController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let supervisor: MonitorSupervisor
    let logger: Logger
    let item: NSStatusItem
    let heading = NSMenuItem(title: "Universal Control Watcher", action: nil, keyEquivalent: "")
    let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let login = NSMenuItem(title: localized("Launch at Login", "Запускать при входе"), action: #selector(toggleAutostart), keyEquivalent: "")
    var timer: Timer?

    init(supervisor: MonitorSupervisor, logger: Logger) {
        self.supervisor = supervisor; self.logger = logger
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        let image = NSImage(systemSymbolName: "display", accessibilityDescription: "UC Watchdog")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Universal Control Watcher"
        rebuildMenu()
    }

    private func rebuildMenu() {
        item.menu?.removeAllItems()
        login.title = localized("Launch at Login", "Запускать при входе")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        heading.isEnabled = false
        menu.addItem(heading)
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        for entry in [login,
                      NSMenuItem(title: localized("Open Log", "Открыть журнал"), action: #selector(openLog), keyEquivalent: ""),
                      NSMenuItem(title: localized("Show App in Finder", "Показать приложение в Finder"), action: #selector(revealApp), keyEquivalent: ""),
                      NSMenuItem(title: localized("Login Items Settings…", "Настройки объектов входа…"), action: #selector(openLoginSettings), keyEquivalent: "")] {
            entry.target = self
            menu.addItem(entry)
        }
        let language = NSMenuItem(title: localized("Language", "Язык"), action: nil, keyEquivalent: "")
        let languages = NSMenu()
        languages.autoenablesItems = false
        for value in AppLanguage.allCases {
            let entry = NSMenuItem(title: value == .english ? "English" : "Русский",
                                   action: #selector(selectLanguage(_:)), keyEquivalent: "")
            entry.representedObject = value.rawValue
            entry.state = value == AppLanguage.current ? .on : .off
            entry.target = self
            languages.addItem(entry)
        }
        language.submenu = languages
        menu.addItem(language)
        menu.addItem(.separator())
        let about = NSMenuItem(title: localized("About…", "О программе…"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self; menu.addItem(about)
        let uninstall = NSMenuItem(title: localized("Uninstall App…", "Удалить приложение…"), action: #selector(uninstall), keyEquivalent: "")
        uninstall.target = self; menu.addItem(uninstall)
        let quit = NSMenuItem(title: localized("Stop", "Остановить"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        item.menu = menu
        refresh()
    }

    func run() {
        supervisor.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.supervisor.tick(); self?.refresh()
        }
    }

    func refresh() {
        status.title = supervisor.isRunning
            ? (supervisor.configuration.dryRun ? localized("Observation Only", "Только наблюдение") : localized("Active", "Активен"))
            : (supervisor.policy.wanted ? localized("Restarting…", "Перезапускается…") : localized("Stopped", "Остановлен"))
        login.state = SMAppService.mainApp.status == .enabled ? .on
            : (SMAppService.mainApp.status == .requiresApproval ? .mixed : .off)
        item.button?.appearsDisabled = !supervisor.isRunning
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    @objc func selectLanguage(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let language = AppLanguage(rawValue: value) else { return }
        AppLanguage.current = language
        rebuildMenu()
    }

    func languageSelectionSelfTest() throws {
        let defaults = AppLanguage.preferences
        let original = defaults.object(forKey: "interfaceLanguage")
        defer {
            if let original { defaults.set(original, forKey: "interfaceLanguage") }
            else { defaults.removeObject(forKey: "interfaceLanguage") }
            defaults.synchronize()
            rebuildMenu()
        }
        for language in [AppLanguage.russian, .english] {
            guard let menu = item.menu?.item(withTitle: localized("Language", "Язык"))?.submenu,
                  let index = menu.items.firstIndex(where: { $0.representedObject as? String == language.rawValue }) else {
                throw WatchError.message("Language menu item missing")
            }
            // Dispatch through AppKit, just as a click does; do not call the selector directly.
            menu.performActionForItem(at: index)
            let title = localized("Language", "Язык", language: language)
            guard AppLanguage.current == language,
                  login.title == localized("Launch at Login", "Запускать при входе", language: language),
                  let rebuilt = item.menu?.item(withTitle: title)?.submenu,
                  rebuilt.items.first(where: { $0.state == .on })?.representedObject as? String == language.rawValue else {
                throw WatchError.message("Language click did not persist or rebuild the menu")
            }
        }
    }

    @objc func toggleAutostart() {
        do {
            // A mixed state requires system approval, not another registration attempt.
            if SMAppService.mainApp.status == .requiresApproval { openLoginSettings(); return }
            try setAutostart(SMAppService.mainApp.status != .enabled)
            logger.write("Autostart \(autostartStatus())")
            if SMAppService.mainApp.status == .requiresApproval { openLoginSettings() }
            refresh()
        } catch { showError(error) }
    }

    @objc func openLog() {
        NSWorkspace.shared.open(supervisor.directory.appendingPathComponent("watchdog.log"))
    }
    @objc func revealApp() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    @objc func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    @objc func showAbout() {
        let credits = NSMutableAttributedString(string: localized("Automatic Universal Control recovery between Macs.", "Автоматическое восстановление Universal Control между Mac."),
            attributes: [.font: NSFont.systemFont(ofSize: 12)])
        if let author = Bundle.main.object(forInfoDictionaryKey: "UCWatchdogAuthor") as? String, !author.isEmpty {
            credits.append(NSAttributedString(string: localized("\n\nAuthor: \(author)", "\n\nАвтор: \(author)"),
                attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        }
        if let source = Bundle.main.object(forInfoDictionaryKey: "UCWatchdogSourceURL") as? String,
           let url = URL(string: source), ["https", "http"].contains(url.scheme), url.host != nil {
            credits.append(NSAttributedString(string: localized("\n\nApplication source code", "\n\nИсходный код приложения"),
                attributes: [.link: url, .font: NSFont.systemFont(ofSize: 12)]))
        }
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "Universal Control Watcher", .credits: credits
        ])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc func uninstall() {
        let alert = NSAlert()
        alert.messageText = localized("Uninstall UC Watchdog?", "Удалить UC Watchdog?")
        alert.informativeText = localized("The monitor will stop, and the application and login item will be removed. Logs and history will be retained.", "Монитор будет остановлен, приложение и автозапуск удалены. Журналы и история останутся.")
        alert.addButton(withTitle: localized("Uninstall", "Удалить"))
        alert.addButton(withTitle: localized("Cancel", "Отмена"))
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let wasRunning = supervisor.policy.wanted
        supervisor.stop()
        do { try manage("uninstall", []); quit() }
        catch {
            if wasRunning { supervisor.start() }
            showError(error)
        }
    }

    @objc func quit() {
        timer?.invalidate()
        supervisor.stop()
        NSStatusBar.system.removeStatusItem(item)
        NSApplication.shared.terminate(nil)
    }
    func applicationWillTerminate(_ notification: Notification) { supervisor.stop() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        refresh(); return false
    }
    private func showError(_ error: Error) {
        logger.write("Menu action failed: \(error)")
        let alert = NSAlert()
        alert.messageText = localized("Could not complete the action", "Не удалось выполнить действие")
        alert.informativeText = String(describing: error)
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

func menuBar(_ arguments: [String]) throws {
    try requireApplicationBundle()
    let directory = URL(fileURLWithPath: option("--state-dir", default: defaultStateDirectory().path, in: arguments))
    let logger = try Logger(directory, echo: false)
    let lockFD = open(directory.appendingPathComponent("menu.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
    guard lockFD >= 0 else { throw WatchError.message("Cannot open menu lock") }
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { close(lockFD); return }
    defer { close(lockFD) }
    var configuration = try WatchConfiguration.load(from: directory)
    if arguments.contains("--dry-run") { configuration.dryRun = true }
    NSApplication.shared.setActivationPolicy(.accessory)
    let supervisor = MonitorSupervisor(directory: directory, configuration: configuration, logger: logger)
    let controller = MenuBarController(supervisor: supervisor, logger: logger)
    NSApplication.shared.delegate = controller
    controller.run()
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    term.setEventHandler { controller.quit() }; interrupt.setEventHandler { controller.quit() }
    term.resume(); interrupt.resume()
    let duration = Double(option("--duration", default: "0", in: arguments)) ?? 0
    if duration > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + duration) { controller.quit() } }
    withExtendedLifetime((term, interrupt, controller)) { NSApplication.shared.run() }
}

// Exercise the actual menu actions and child lifecycle in an isolated dry-run session.
// This test never changes login-item registration or sends signals to UC services.
func menuSelfTest() throws {
    try requireApplicationBundle()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("uc-watchdog-menu-test-\(UUID().uuidString)")
    let logger = try Logger(directory)
    NSApplication.shared.setActivationPolicy(.accessory)
    // Opening a distributed copy must not install or start anything after Cancel.
    if Bundle.main.bundleURL.standardizedFileURL != installedApplicationURL().standardizedFileURL {
        let registration = SMAppService.mainApp.status
        var offeredCancellation = false
        try launchApplication { alert in
            offeredCancellation = alert.buttons.last?.title == localized("Cancel", "Отмена")
            return alert.buttons.count == 3 ? .alertThirdButtonReturn : .alertSecondButtonReturn
        }
        guard offeredCancellation, SMAppService.mainApp.status == registration else {
            throw WatchError.message("Startup cancellation changed autostart")
        }
    }
    try peerPickerSelfTest()
    let supervisor = MonitorSupervisor(directory: directory, configuration: WatchConfiguration(dryRun: true), logger: logger)
    let controller = MenuBarController(supervisor: supervisor, logger: logger)
    try controller.languageSelectionSelfTest()
    guard let languages = controller.item.menu?.item(withTitle: localized("Language", "Язык"))?.submenu,
          languages.items.map({ $0.title }) == ["English", "Русский"],
          languages.items.allSatisfy({ $0.action == #selector(MenuBarController.selectLanguage(_:)) }),
          languages.items.filter({ $0.state == .on }).count == 1,
          languages.items.first(where: { $0.state == .on })?.representedObject as? String == AppLanguage.current.rawValue else {
        throw WatchError.message("Language menu selection failed")
    }
    NSApplication.shared.delegate = controller
    func finish(_ error: String?) {
        supervisor.stop()
        controller.timer?.invalidate()
        try? FileManager.default.removeItem(at: directory)
        if let error {
            FileHandle.standardError.write(Data("Menu self-test failed: \(error)\n".utf8))
            exit(1)
        }
        print("Menu self-test passed: language clicks, stop action, child lifecycle and crash retry; no service signals sent")
        controller.quit()
    }
    controller.run()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        guard supervisor.isRunning,
              controller.item.menu?.item(withTitle: localized("Stop", "Остановить"))?.action == #selector(MenuBarController.quit)
            else { finish("Initial menu/monitor state"); return }
        supervisor.stop(); controller.refresh()
        guard !supervisor.isRunning, !supervisor.policy.wanted,
              controller.status.title == localized("Stopped", "Остановлен") else { finish("Stop child"); return }
        supervisor.start(); controller.refresh()
        guard supervisor.isRunning else { finish("Resume action"); return }
        // Terminate only our dry-run child to simulate a crash.
        supervisor.process?.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard !supervisor.isRunning, supervisor.policy.wanted,
                  supervisor.policy.nextStart.timeIntervalSinceNow > 25 else { finish("Crash retry throttle"); return }
            supervisor.stop()
            supervisor.tick()
            guard !supervisor.isRunning, !supervisor.policy.wanted else { finish("Stopped monitor restarted"); return }
            finish(nil)
        }
    }
    withExtendedLifetime(controller) { NSApplication.shared.run() }
}
