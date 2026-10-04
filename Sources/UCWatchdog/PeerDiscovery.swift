import AppKit

struct PeerCandidate: Equatable {
    let prefix: String
    var name: String?
    var model: String?
    var lastSeen: String
    var title: String { "\(name ?? model ?? "Устройство Universal Control") — \(prefix)" }
}

struct PeerCollector {
    private var peers: [String: PeerCandidate] = [:]
    private var localPrefixes: Set<String> = []
    private static let ids = try! NSRegularExpression(pattern: #"\bIDS (?:'([0-9A-F]{8})'|([0-9A-F]{8}):)"#)
    private static let name = try! NSRegularExpression(pattern: #"\bNm '([^']+)'"#)
    private static let model = try! NSRegularExpression(pattern: #"\bMd (?:'([^']+)'|([A-Za-z]+[0-9]+,[0-9]+|[A-Za-z][A-Za-z0-9.-]*))"#)

    private static func capture(_ expression: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range) else { return nil }
        for index in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: index), in: text) { return String(text[range]) }
        }
        return nil
    }

    mutating func record(_ message: String, timestamp: String) {
        guard let prefix = Self.capture(Self.ids, in: message) else { return }
        if message.contains("Local Device Change:") { localPrefixes.insert(prefix); return }
        var candidate = peers[prefix] ?? PeerCandidate(prefix: prefix, lastSeen: timestamp)
        if let name = Self.capture(Self.name, in: message), name != "<private>", !name.isEmpty { candidate.name = name }
        if let model = Self.capture(Self.model, in: message), model != "<private>" { candidate.model = model }
        candidate.lastSeen = max(candidate.lastSeen, timestamp)
        peers[prefix] = candidate
    }

    mutating func line(_ data: Data) {
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["subsystem"] as? String == "com.apple.universalcontrol",
              let message = record["eventMessage"] as? String else { return }
        self.record(message, timestamp: record["timestamp"] as? String ?? "")
    }

    var candidates: [PeerCandidate] {
        peers.values.filter { candidate in
            let model = candidate.model?.lowercased() ?? ""
            return !localPrefixes.contains(candidate.prefix)
                && !["ipad", "iphone", "ipod", "appletv", "watch", "applewatch"].contains(where: {
                    model.hasPrefix($0) || model.hasPrefix("com.apple.\($0)")
                })
        }.sorted {
            $0.lastSeen == $1.lastSeen ? $0.prefix < $1.prefix : $0.lastSeen > $1.lastSeen
        }
    }
}

func discoverPeers() throws -> [PeerCandidate] {
    let process = Process(); let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    process.arguments = ["show", "--last", "24h", "--style", "ndjson", "--info", "--predicate",
        "subsystem == \"com.apple.universalcontrol\" AND eventMessage CONTAINS \"IDS \" AND NOT eventMessage CONTAINS \"/SYNC:\""]
    process.standardOutput = pipe; process.standardError = pipe
    try process.run()
    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
    defer { timeout.cancel() }
    var pending = Data(); var collector = PeerCollector(); var diagnostics = ""
    while let data = try pipe.fileHandleForReading.read(upToCount: 65_536), !data.isEmpty {
        pending.append(data)
        while let end = pending.firstIndex(of: 10) {
            let line = Data(pending.prefix(upTo: end)); pending.removeSubrange(...end)
            if line.first == 123 { collector.line(line) }
            else if diagnostics.count < 2000 { diagnostics += String(data: line, encoding: .utf8) ?? "" }
        }
        if pending.count > 1_000_000 { process.terminate(); process.waitUntilExit(); throw WatchError.message("Oversized discovery log record") }
    }
    if !pending.isEmpty { collector.line(pending) }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw WatchError.message("Не удалось прочитать журнал Universal Control за последние сутки. \(diagnostics.prefix(2000))")
    }
    return collector.candidates
}

private final class DiscoveryResult {
    let lock = NSLock()
    private var value: Result<[PeerCandidate], Error>?
    func set(_ result: Result<[PeerCandidate], Error>) { lock.lock(); defer { lock.unlock() }; value = result }
    func get() -> Result<[PeerCandidate], Error>? { lock.lock(); defer { lock.unlock() }; return value }
}

private func scanWithProgress(scan: @escaping () throws -> [PeerCandidate] = discoverPeers) throws -> [PeerCandidate]? {
    let result = DiscoveryResult()
    let alert = NSAlert()
    alert.messageText = "Поиск устройств Universal Control…"
    alert.informativeText = "Читаем события за последние сутки. Это может занять несколько секунд."
    alert.addButton(withTitle: "Отмена")
    let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
    spinner.style = .spinning; spinner.startAnimation(nil); alert.accessoryView = spinner
    DispatchQueue.global(qos: .userInitiated).async { result.set(Result { try scan() }) }
    let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
        if result.get() != nil { NSApplication.shared.stopModal(withCode: .alertSecondButtonReturn) }
    }
    RunLoop.main.add(timer, forMode: .modalPanel)
    let response = alert.runModal()
    timer.invalidate()
    spinner.stopAnimation(nil)
    alert.window.orderOut(nil)
    guard response == .alertSecondButtonReturn, let value = result.get() else { return nil }
    return try value.get()
}

private final class PeerSelection: NSObject {
    let popup: NSPopUpButton
    let button: NSButton
    init(popup: NSPopUpButton, button: NSButton) { self.popup = popup; self.button = button }
    @objc func changed() { button.isEnabled = popup.indexOfSelectedItem > 0 }
}

func choosePeer(scan: () throws -> [PeerCandidate]? = { try scanWithProgress() },
                confirm: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }) throws -> String? {
    while true {
        guard let candidates = try scan() else { return nil }
        let alert = NSAlert()
        alert.messageText = candidates.isEmpty ? "Устройства не найдены" : "Какой Mac отслеживать?"
        alert.informativeText = candidates.isEmpty
            ? "Включите Universal Control на обоих Mac, поднесите их ближе и попробуйте перевести указатель на другой экран. Затем обновите список."
            : "Выберите Mac, связь с которым нужно восстанавливать. Список составлен по событиям за последние сутки; устройство сейчас может быть недоступно."
        if candidates.isEmpty {
            alert.addButton(withTitle: "Обновить список"); alert.addButton(withTitle: "Отмена")
            guard confirm(alert) == .alertFirstButtonReturn else { return nil }
        } else {
            alert.addButton(withTitle: "Установить"); alert.addButton(withTitle: "Обновить список"); alert.addButton(withTitle: "Отмена")
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 440, height: 28), pullsDown: false)
            popup.addItem(withTitle: "Выберите устройство…")
            for candidate in candidates { popup.addItem(withTitle: candidate.title); popup.lastItem?.representedObject = candidate.prefix }
            let selection = PeerSelection(popup: popup, button: alert.buttons[0])
            popup.target = selection; popup.action = #selector(PeerSelection.changed)
            selection.changed(); alert.accessoryView = popup
            let response = withExtendedLifetime(selection) { confirm(alert) }
            if response == .alertFirstButtonReturn { return popup.selectedItem?.representedObject as? String }
            if response != .alertSecondButtonReturn { return nil }
        }
    }
}

func peerDiscoverySelfTest() throws {
    var collector = PeerCollector()
    collector.record("IDS 3047DD83: Device Found SF <LocalDevice MeDeviceIsMe>, Md Mac16,7", timestamp: "2026-10-04 10:00")
    collector.record("Remote Device Change: P2PDevice, IDS '3047DD83' Nm 'Work Mac' Md 'Mac16,7'", timestamp: "2026-10-04 10:01")
    collector.record("IDS 3047DD83: Connected", timestamp: "2026-10-04 10:02")
    collector.record("IDS 2EF0ACDC: Connected", timestamp: "2026-10-04 10:03")
    collector.record("CID 00000001: Local Device Change: P2PDevice, IDS '2EF0ACDC' Nm 'This Mac'", timestamp: "2026-10-04 10:04")
    collector.record("Nearby: [AAAAAAAA] CID DEADBEEF", timestamp: "2026-10-04 10:05")
    collector.record("IDS 3047DD830: Connected", timestamp: "2026-10-04 10:06")
    guard collector.candidates.count == 1, collector.candidates[0].prefix == "3047DD83",
          collector.candidates[0].model == "Mac16,7", collector.candidates[0].name == "Work Mac" else {
        throw WatchError.message("Peer discovery/local exclusion/deduplication failed")
    }
    collector.record("IDS FFFFFFFF: Device Found, Md iPhone16,1", timestamp: "2026-10-04 10:07")
    collector.record("IDS EEEEEEEE: Device Found, Md Watch7,5", timestamp: "2026-10-04 10:07")
    collector.record("Remote Device Change: IDS 'DDDDDDDD' Md 'com.apple.ipad-pro'", timestamp: "2026-10-04 10:07")
    guard collector.candidates.count == 1 else { throw WatchError.message("Non-Mac device filter failed") }
    collector.record("Remote Device Change: IDS '3047DD83' Nm '<private>'", timestamp: "2026-10-04 10:08")
    guard collector.candidates[0].name == "Work Mac" else { throw WatchError.message("Private device name handling failed") }
    collector.line(Data(#"{"subsystem":"other","eventMessage":"IDS ABCDEF12: Connected"}"#.utf8))
    collector.line(Data("not JSON".utf8))
    guard collector.candidates.count == 1 else { throw WatchError.message("Discovery log input filter failed") }
}

func peerPickerSelfTest() throws {
    let candidates = [PeerCandidate(prefix: "11111111", name: "First Mac", lastSeen: ""),
                      PeerCandidate(prefix: "22222222", name: "Second Mac", lastSeen: "")]
    guard try scanWithProgress(scan: { candidates }) == candidates else {
        throw WatchError.message("Discovery progress result failed")
    }
    var validSelection = false
    let selected = try choosePeer(scan: { candidates }, confirm: { alert in
        guard let popup = alert.accessoryView as? NSPopUpButton, !alert.buttons[0].isEnabled else { return .alertThirdButtonReturn }
        popup.selectItem(at: 2)
        if let action = popup.action { popup.sendAction(action, to: popup.target) }
        validSelection = alert.buttons[0].isEnabled
        return .alertFirstButtonReturn
    })
    guard validSelection, selected == "22222222" else { throw WatchError.message("Explicit peer picker selection failed") }
    guard try choosePeer(scan: { candidates }, confirm: { _ in .alertThirdButtonReturn }) == nil,
          try choosePeer(scan: { [] }, confirm: { _ in .alertSecondButtonReturn }) == nil else {
        throw WatchError.message("Peer picker cancellation failed")
    }
}
