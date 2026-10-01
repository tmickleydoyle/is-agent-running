// Agent Snake — orange snakes that circle your screen edges while Claude Code agents are working.
//
//   agent-snake                  run the overlay (normally started by launchd)
//   agent-snake hook             Claude Code hook entry point (reads hook JSON on stdin)
//   agent-snake install-hooks    add hooks to ~/.claude/settings.json
//   agent-snake uninstall-hooks  remove them again

import AppKit
import Darwin

// MARK: - Shared

let home = ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser
let baseDir = home.appendingPathComponent(".claude/agent-snake")
let sessionsDir = baseDir.appendingPathComponent("sessions")
let settingsURL = home.appendingPathComponent(".claude/settings.json")

struct SessionRecord: Codable {
    var session_id: String
    var state: String  // idle | running | waiting | done
    var pid: Int32
    var cwd: String
    var transcript: String
    var updated: Double
}

func recordURL(_ sessionID: String) -> URL {
    let safe = String(sessionID.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
    return sessionsDir.appendingPathComponent("\(safe).json")
}

func readRecord(_ url: URL) -> SessionRecord? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(SessionRecord.self, from: data)
}

func writeRecord(_ rec: SessionRecord) {
    try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(rec) {
        try? data.write(to: recordURL(rec.session_id), options: .atomic)
    }
}

func processAlive(_ pid: Int32) -> Bool {
    pid <= 0 || kill(pid, 0) == 0 || errno != ESRCH
}

// MARK: - Hook mode

func procInfo(_ pid: pid_t) -> (name: String, ppid: pid_t)? {
    var kp = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
    let name = withUnsafePointer(to: kp.kp_proc.p_comm) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: kp.kp_proc.p_comm)) { String(cString: $0) }
    }
    return (name, kp.kp_eproc.e_ppid)
}

func procPath(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
}

/// The `claude` process that ran this hook, so the overlay can drop the snake if the session dies.
func claudeAncestorPID() -> Int32 {
    var pid = getppid()
    for _ in 0..<10 {
        guard pid > 1, let info = procInfo(pid) else { break }
        // The native binary reports its version (e.g. "2.1.286") as its name, so check the path too.
        if info.name.lowercased().hasPrefix("claude") || procPath(pid).lowercased().contains("claude") { return pid }
        pid = info.ppid
    }
    return 0
}

func runHook() -> Never {
    // Never print anything: stdout from some hooks is fed back into Claude's context.
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let obj = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
          let sid = obj["session_id"] as? String, !sid.isEmpty else { exit(0) }
    let event = obj["hook_event_name"] as? String ?? ""
    let url = recordURL(sid)
    let existing = readRecord(url)

    let newState: String
    switch event {
    case "SessionEnd":
        try? FileManager.default.removeItem(at: url)
        exit(0)
    case "SessionStart":
        newState = "idle"
    case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionDenied":
        newState = "running"
    case "SubagentStop":
        // A background subagent can finish after the main agent stopped; don't revive a finished snake.
        guard let current = existing?.state, current == "running" || current == "waiting" else { exit(0) }
        newState = "running"
    case "PermissionRequest":
        newState = "waiting"
    case "Notification":
        guard let current = existing?.state, current == "running" || current == "waiting" else { exit(0) }
        switch obj["notification_type"] as? String ?? "" {
        case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
            newState = "waiting"
        case "idle_prompt":
            newState = "done"  // Claude has been sitting idle — finished, not blocked
        default:
            exit(0)
        }
    case "Stop", "StopFailure":
        newState = "done"
    default:
        exit(0)
    }

    var pid = existing?.pid ?? 0
    if pid <= 0 || !processAlive(pid) { pid = claudeAncestorPID() }
    writeRecord(SessionRecord(
        session_id: sid,
        state: newState,
        pid: pid,
        cwd: obj["cwd"] as? String ?? existing?.cwd ?? "",
        transcript: obj["transcript_path"] as? String ?? existing?.transcript ?? "",
        updated: Date().timeIntervalSince1970))
    exit(0)
}

// MARK: - Settings install

let hookEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                  "PermissionRequest", "PermissionDenied", "SubagentStop", "Notification", "Stop", "StopFailure", "SessionEnd"]
let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PermissionDenied"]

func isOurHook(_ h: Any) -> Bool {
    ((h as? [String: Any])?["command"] as? String)?.contains("agent-snake") ?? false
}

func loadSettings() -> [String: Any] {
    guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
    guard let data = try? Data(contentsOf: settingsURL),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        FileHandle.standardError.write("~/.claude/settings.json is not valid JSON; not touching it.\n".data(using: .utf8)!)
        exit(1)
    }
    return root
}

func saveSettings(_ root: [String: Any]) {
    let backup = settingsURL.appendingPathExtension("agent-snake-backup")
    if FileManager.default.fileExists(atPath: settingsURL.path) {
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: settingsURL, to: backup)
    }
    let data = try! JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try! data.write(to: settingsURL, options: .atomic)
}

/// Removes our hook entries from a settings `hooks` dictionary, dropping groups/events left empty.
func strippedHooks(_ hooks: [String: Any]) -> [String: Any] {
    var out = hooks
    for (event, value) in hooks {
        guard let groups = value as? [[String: Any]] else { continue }
        let kept: [[String: Any]] = groups.compactMap { group in
            guard let list = group["hooks"] as? [Any] else { return group }
            let remaining = list.filter { !isOurHook($0) }
            if remaining.isEmpty { return nil }
            var g = group
            g["hooks"] = remaining
            return g
        }
        out[event] = kept.isEmpty ? nil : kept
    }
    return out
}

func installHooks(binary: String) {
    var root = loadSettings()
    var hooks = strippedHooks(root["hooks"] as? [String: Any] ?? [:])
    let command = "'\(binary)' hook"
    for event in hookEvents {
        var groups = hooks[event] as? [[String: Any]] ?? []
        var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
        if toolEvents.contains(event) { group["matcher"] = "*" }
        groups.append(group)
        hooks[event] = groups
    }
    root["hooks"] = hooks
    saveSettings(root)
    print("Installed Agent Snake hooks into \(settingsURL.path)")
}

func uninstallHooks() {
    var root = loadSettings()
    let hooks = strippedHooks(root["hooks"] as? [String: Any] ?? [:])
    root["hooks"] = hooks.isEmpty ? nil : hooks
    saveSettings(root)
    print("Removed Agent Snake hooks from \(settingsURL.path)")
}

// MARK: - Transcript check

/// Esc-interrupts don't fire the Stop hook, so look for Claude Code's interrupt marker
/// as the latest user/assistant entry in the transcript.
func transcriptShowsInterrupt(_ path: String) -> Bool {
    guard !path.isEmpty, let fh = FileHandle(forReadingAtPath: path) else { return false }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    try? fh.seek(toOffset: size > 65536 ? size - 65536 : 0)
    let text = String(decoding: fh.readDataToEndOfFile(), as: UTF8.self)
    for line in text.split(separator: "\n").reversed() {
        guard let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let type = entry["type"] as? String, type == "user" || type == "assistant" else { continue }
        guard type == "user", let message = entry["message"] as? [String: Any] else { return false }
        var firstText = message["content"] as? String
        if firstText == nil, let parts = message["content"] as? [[String: Any]], let first = parts.first,
           first["type"] as? String == "text" {
            firstText = first["text"] as? String
        }
        return firstText?.hasPrefix("[Request interrupted by user") ?? false
    }
    return false
}

// MARK: - Overlay

let cellSize: CGFloat = 10      // grid pitch in points
let segmentSize: CGFloat = 7    // drawn square inside each cell
let snakeLength = 14
let ticksPerSecond = 16.0
let dyingTicks = 24             // ~1.5s of flashing when an agent finishes

let palette: [NSColor] = [
    NSColor(srgbRed: 1.00, green: 0.48, blue: 0.00, alpha: 1),  // orange
    NSColor(srgbRed: 0.20, green: 0.55, blue: 1.00, alpha: 1),  // blue
    NSColor(srgbRed: 0.20, green: 0.80, blue: 0.30, alpha: 1),  // green
    NSColor(srgbRed: 0.95, green: 0.25, blue: 0.60, alpha: 1),  // pink
    NSColor(srgbRed: 0.62, green: 0.38, blue: 1.00, alpha: 1),  // purple
    NSColor(srgbRed: 1.00, green: 0.85, blue: 0.10, alpha: 1),  // yellow
    NSColor(srgbRed: 0.10, green: 0.80, blue: 0.85, alpha: 1),  // cyan
    NSColor(srgbRed: 0.90, green: 0.15, blue: 0.15, alpha: 1),  // red
]

final class Snake {
    let id: String
    var state: String
    var color: NSColor
    var phase: Double   // starting point as a fraction of the perimeter
    var cells = 0       // how far it has crawled
    var dying: Int?     // tick counter while flashing out

    init(id: String, state: String, color: NSColor, phase: Double) {
        self.id = id; self.state = state; self.color = color; self.phase = phase
    }

    var isActive: Bool { dying == nil && (state == "running" || state == "waiting") }
}

final class Overlay {
    let window: NSWindow
    let root: CALayer
    let scale: CGFloat
    let cols: Int, rows: Int, perimeter: Int
    let origin: CGPoint
    var layers: [String: (body: CAShapeLayer, head: CAShapeLayer)] = [:]

    init(screen: NSScreen) {
        let frame = screen.frame
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        window.contentView = view
        root = view.layer!
        scale = screen.backingScaleFactor

        cols = max(2, Int(frame.width / cellSize))
        rows = max(2, Int(frame.height / cellSize))
        perimeter = 2 * (cols - 1) + 2 * (rows - 1)
        origin = CGPoint(x: (frame.width - CGFloat(cols) * cellSize) / 2,
                         y: (frame.height - CGFloat(rows) * cellSize) / 2)
        window.orderFrontRegardless()
    }

    /// Clockwise around the edge, starting at the top-left corner.
    func cellRect(_ index: Int) -> CGRect {
        var i = index % perimeter
        if i < 0 { i += perimeter }
        let top = cols - 1, right = rows - 1
        let (c, r): (Int, Int)
        if i < top { (c, r) = (i, rows - 1) }
        else if i < top + right { (c, r) = (cols - 1, rows - 1 - (i - top)) }
        else if i < 2 * top + right { (c, r) = (cols - 1 - (i - top - right), 0) }
        else { (c, r) = (0, i - 2 * top - right) }
        let inset = (cellSize - segmentSize) / 2
        return CGRect(x: origin.x + CGFloat(c) * cellSize + inset,
                      y: origin.y + CGFloat(r) * cellSize + inset,
                      width: segmentSize, height: segmentSize)
    }

    func headIndex(_ s: Snake) -> Int {
        Int((s.phase * Double(perimeter)).rounded()) + s.cells
    }

    func makeLayer(_ color: CGColor) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.contentsScale = scale
        l.fillColor = color
        l.strokeColor = NSColor(white: 0, alpha: 0.35).cgColor
        l.lineWidth = 0.75
        root.addSublayer(l)
        return l
    }

    func render(_ snakes: [Snake], tick: Int, hidden: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let ids = Set(snakes.map(\.id))
        for (id, pair) in layers where !ids.contains(id) || hidden {
            pair.body.removeFromSuperlayer(); pair.head.removeFromSuperlayer()
            layers[id] = nil
        }
        if hidden { return }

        for s in snakes {
            let pair = layers[s.id] ?? (makeLayer(s.color.cgColor), makeLayer(s.color.blended(withFraction: 0.35, of: .black)!.cgColor))
            layers[s.id] = pair

            let head = headIndex(s)
            let body = CGMutablePath()
            for i in 1..<snakeLength {
                body.addRoundedRect(in: cellRect(head - i), cornerWidth: 1.5, cornerHeight: 1.5)
            }
            pair.body.path = body
            pair.head.path = CGPath(roundedRect: cellRect(head), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)

            var opacity: Float = 1
            if let d = s.dying {
                opacity = (d / 3) % 2 == 0 ? 1 : 0
            } else if s.state == "waiting" {
                // Frozen and breathing: Claude needs you (permission prompt etc).
                opacity = Float(0.25 + 0.75 * (0.5 + 0.5 * cos(Double(tick) * 2 * .pi / ticksPerSecond)))
            }
            pair.body.opacity = opacity
            pair.head.opacity = opacity
        }
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var overlays: [Overlay] = []
    var snakes: [String: Snake] = [:]
    var records: [SessionRecord] = []
    var tick = 0
    var statusItem: NSStatusItem!
    var hidden = UserDefaults.standard.bool(forKey: "AgentSnakeHidden")

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        buildOverlays()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.buildOverlays() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        poll()
        // Snakes found on launch shouldn't flash as if they'd just finished.
        snakes = snakes.filter { $0.value.isActive }
        updateStatusTitle()

        let pollTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
        let stepTimer = Timer(timeInterval: 1 / ticksPerSecond, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(pollTimer, forMode: .common)
        RunLoop.main.add(stepTimer, forMode: .common)
    }

    func buildOverlays() {
        overlays.forEach { $0.close() }
        overlays = NSScreen.screens.map { Overlay(screen: $0) }
    }

    // MARK: State

    func poll() {
        let now = Date().timeIntervalSince1970
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        var fresh: [SessionRecord] = []
        for url in files where url.pathExtension == "json" {
            guard var rec = readRecord(url) else { continue }
            if !processAlive(rec.pid) {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if (rec.state == "running" || rec.state == "waiting"), now - rec.updated > 3,
               transcriptShowsInterrupt(rec.transcript) {
                rec.state = "done"
                rec.updated = now
                writeRecord(rec)
            }
            fresh.append(rec)
        }
        records = fresh.sorted { $0.cwd < $1.cwd }

        let byID = Dictionary(fresh.map { ($0.session_id, $0) }, uniquingKeysWith: { a, _ in a })
        for rec in fresh {
            let active = rec.state == "running" || rec.state == "waiting"
            if let s = snakes[rec.session_id] {
                if active { s.state = rec.state; s.dying = nil }
                else if s.isActive { s.state = rec.state; s.dying = 0 }
            } else if active {
                snakes[rec.session_id] = Snake(id: rec.session_id, state: rec.state, color: pickColor(), phase: pickPhase())
            }
        }
        for s in snakes.values where byID[s.id] == nil && s.isActive {
            s.state = "done"; s.dying = 0
        }
        updateStatusTitle()
    }

    func step() {
        tick += 1
        for s in snakes.values {
            if let d = s.dying {
                if d >= dyingTicks { snakes[s.id] = nil } else { s.dying = d + 1 }
            } else if s.state == "running" {
                s.cells += 1
            }
        }
        let ordered = snakes.values.sorted { $0.id < $1.id }
        overlays.forEach { $0.render(ordered, tick: tick, hidden: hidden) }
    }

    func pickColor() -> NSColor {
        let used = snakes.values.map(\.color)
        return palette.first { !used.contains($0) } ?? palette[snakes.count % palette.count]
    }

    /// Drop a new snake into the middle of the biggest gap between existing ones.
    func pickPhase() -> Double {
        guard let main = overlays.first else { return 0 }
        let p = Double(main.perimeter)
        let heads = snakes.values.filter { $0.dying == nil }
            .map { (Double(main.headIndex($0)) / p).truncatingRemainder(dividingBy: 1) }
            .sorted()
        guard let first = heads.first else { return 0.1 }
        var best = (gap: 1 - heads.last! + first, start: heads.last!)
        for (a, b) in zip(heads, heads.dropFirst()) where b - a > best.gap { best = (b - a, a) }
        return (best.start + best.gap / 2).truncatingRemainder(dividingBy: 1)
    }

    // MARK: Menu bar

    func updateStatusTitle() {
        let running = snakes.values.filter(\.isActive).count
        let waiting = snakes.values.filter { $0.isActive && $0.state == "waiting" }.count
        var title = running > 0 ? "🐍 \(running)" : "🐍"
        if waiting > 0 { title += " ⚠︎\(waiting)" }
        statusItem.button?.title = title
        statusItem.button?.appearsDisabled = running == 0
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let active = records.filter { $0.state == "running" || $0.state == "waiting" }
        menu.addItem(withTitle: active.isEmpty ? "No agents running" : "\(active.count) agent\(active.count == 1 ? "" : "s") running",
                     action: nil, keyEquivalent: "")
        if !records.isEmpty { menu.addItem(.separator()) }
        for rec in records {
            let name = rec.cwd.isEmpty ? String(rec.session_id.prefix(8)) : (rec.cwd as NSString).lastPathComponent
            let label: String
            switch rec.state {
            case "running": label = "working"
            case "waiting": label = "needs you"
            case "done": label = "finished"
            default: label = "idle"
            }
            let item = NSMenuItem(title: "\(name) — \(label)", action: nil, keyEquivalent: "")
            item.toolTip = rec.cwd
            if let s = snakes[rec.session_id], s.isActive { item.image = swatch(s.color) }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide Snakes", action: #selector(toggleHidden), keyEquivalent: "")
        hide.target = self
        hide.state = hidden ? .on : .off
        menu.addItem(hide)
        let reset = NSMenuItem(title: "Clear Stuck Snakes", action: #selector(clearAll), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Agent Snake", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
    }

    @objc func toggleHidden() {
        hidden.toggle()
        UserDefaults.standard.set(hidden, forKey: "AgentSnakeHidden")
    }

    @objc func clearAll() {
        for var rec in records where rec.state == "running" || rec.state == "waiting" {
            rec.state = "idle"
            rec.updated = Date().timeIntervalSince1970
            writeRecord(rec)
        }
        snakes.removeAll()
        poll()
    }
}

// MARK: - Entry

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "hook":
    runHook()
case "install-hooks":
    installHooks(binary: args.count > 2 ? args[2] : URL(fileURLWithPath: args[0]).standardizedFileURL.path)
    exit(0)
case "uninstall-hooks":
    uninstallHooks()
    exit(0)
case "":
    break
default:
    print("usage: agent-snake [hook | install-hooks [binary] | uninstall-hooks]")
    exit(2)
}

// Only one overlay at a time.
try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
let lockFD = open(baseDir.appendingPathComponent("overlay.lock").path, O_CREAT | O_RDWR, 0o644)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
