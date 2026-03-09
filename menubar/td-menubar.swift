import Cocoa

class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

enum SessionStatus { case active, waiting }
struct FolderSession {
    let tty: String
    let status: SessionStatus
}

class TD: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    var statusItem: NSStatusItem!
    var autoTile = false
    let tdPath: String = {
        // 1. ~/bin/td (installed by install.sh)
        let home = NSString(string: "~/bin/td").expandingTildeInPath
        if FileManager.default.fileExists(atPath: home) { return home }
        // 2. relative to bundle (dev: TD.app lives next to td in repo)
        let bundle = Bundle.main.bundlePath
        let menubar = (bundle as NSString).deletingLastPathComponent
        let root = (menubar as NSString).deletingLastPathComponent
        let relative = (root as NSString).appendingPathComponent("td")
        if FileManager.default.fileExists(atPath: relative) { return relative }
        // 3. PATH lookup
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["td"]
        let pipe = Pipe()
        which.standardOutput = pipe; which.standardError = Pipe()
        try? which.run(); which.waitUntilExit()
        let found = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return found.isEmpty ? home : found
    }()

    var lastClickTime: Date?
    let doubleClickInterval: TimeInterval = 0.3
    var singleClickTimer: Timer?
    var tileDebounce: Timer?
    var lastCapsTime: Date?
    let capsDoubleTap: TimeInterval = 0.35
    var globalFlagsMonitor: Any?
    var localFlagsMonitor: Any?

    // Quick Add
    var panel: KeyPanel?
    var folderField: NSTextField?
    var promptField: NSTextField?
    var resultsPanel: NSPanel?
    var resultLabels: [NSTextField] = []
    var allFolders: [String] = []
    var filteredFolders: [String] = []
    var selectedIndex: Int = -1
    var selectedFolder: String?
    var folderSessions: [String: FolderSession] = [:]
    let codeDir = NSString(string: "~/Desktop/Code").expandingTildeInPath
    var keyMonitor: Any?

    // Discovery state
    var lastDiscoveryTime: Date?
    let discoveryTTL: TimeInterval = 30
    var isScanning = false

    // Pastel traffic-light colors
    let pastelGreen  = NSColor(red: 0.55, green: 0.85, blue: 0.55, alpha: 1.0)
    let pastelYellow = NSColor(red: 0.92, green: 0.80, blue: 0.42, alpha: 1.0)
    let pastelGray   = NSColor(white: 0.45, alpha: 0.6)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "td")
            button.image?.size = NSSize(width: 16, height: 16)
            button.action = #selector(clicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Hidden Edit menu so ⌘V/⌘C/⌘X/⌘A work in text fields
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut",        action: #selector(NSText.cut(_:)),       keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",       action: #selector(NSText.copy(_:)),      keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",      action: #selector(NSText.paste(_:)),     keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu

        // Global hotkey: double-tap Caps Lock to open Quick Add
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleCapsLock(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleCapsLock(event)
            return event
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(spaceChanged),
            name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(spaceChanged),
            name: NSNotification.Name("com.apple.spaces.activeSpaceDidChange"), object: nil
        )

        validateTdPath()
        checkiTermPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = globalFlagsMonitor { NSEvent.removeMonitor(m) }
        if let m = localFlagsMonitor  { NSEvent.removeMonitor(m) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - Launch validation

    func validateTdPath() {
        guard FileManager.default.fileExists(atPath: tdPath) else {
            let alert = NSAlert()
            alert.messageText = "td script not found"
            alert.informativeText = "Expected at:\n\(tdPath)\n\nMove TD.app back into the term_dashboard repo root."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
    }

    func checkiTermPermission() {
        DispatchQueue.global(qos: .background).async {
            let src = "tell application \"iTerm2\" to return name"
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
            guard let error = err else { return }
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            guard code == -1743 || code == -1744 else { return }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Automation permission needed"
                alert.informativeText = "TD needs permission to control iTerm2.\n\nGo to System Settings → Privacy & Security → Automation and enable iTerm2 for TD."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Dismiss")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }
            }
        }
    }

    // MARK: - Caps Lock

    func handleCapsLock(_ event: NSEvent) {
        guard event.keyCode == 57 else { return }
        if let p = panel, p.isVisible { return }

        let now = Date()
        if let last = lastCapsTime, now.timeIntervalSince(last) < capsDoubleTap {
            lastCapsTime = nil
            DispatchQueue.main.async { self.showQuickAdd() }
        } else {
            lastCapsTime = now
        }
    }

    @objc func spaceChanged() {
        guard autoTile else { return }
        tileDebounce?.invalidate()
        tileDebounce = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { _ in
            if let p = self.panel, p.isVisible { return }
            self.run("tile")
            self.flash()
        }
    }

    // MARK: - Click handling

    @objc func clicked() {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showMenu()
            return
        }

        let now = Date()
        if let last = lastClickTime, now.timeIntervalSince(last) < doubleClickInterval {
            singleClickTimer?.invalidate()
            singleClickTimer = nil
            lastClickTime = nil
            showMenu()
        } else {
            lastClickTime = now
            singleClickTimer?.invalidate()
            singleClickTimer = Timer.scheduledTimer(withTimeInterval: doubleClickInterval, repeats: false) { _ in
                self.lastClickTime = nil
                self.showQuickAdd()
            }
        }
    }

    // MARK: - Folder scanning (async, non-blocking)

    func scanFolders(completion: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            guard let items = try? fm.contentsOfDirectory(atPath: self.codeDir) else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let folders = items.filter { name in
                var isDir: ObjCBool = false
                let full = (self.codeDir as NSString).appendingPathComponent(name)
                return fm.fileExists(atPath: full, isDirectory: &isDir) && isDir.boolValue && !name.hasPrefix(".")
            }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            DispatchQueue.main.async { completion(folders) }
        }
    }

    // MARK: - Active session discovery (1 ps + 1 batched lsof)

    func discoverActiveFolders() {
        // Respect TTL — skip if recently refreshed
        if let last = lastDiscoveryTime, Date().timeIntervalSince(last) < discoveryTTL { return }

        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let sessions = self.runDiscovery()
            DispatchQueue.main.async {
                self.folderSessions = sessions
                self.lastDiscoveryTime = Date()
                self.isScanning = false
                if self.resultsPanel?.isVisible == true { self.showResults() }
            }
        }
    }

    /// Core discovery: 1 ps + 1 batched lsof for all claude TTYs
    private func runDiscovery() -> [String: FolderSession] {
        // Single ps for all processes
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-eo", "tty,pid,comm,%cpu"]
        let psPipe = Pipe()
        ps.standardOutput = psPipe
        ps.standardError = Pipe()
        try? ps.run(); ps.waitUntilExit()
        let psOut = String(data: psPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        // Parse: TTY → max claude CPU, TTY → first shell PID
        var ttyCpu: [String: Double] = [:]
        var ttyShellPids: [String: String] = [:]
        for line in psOut.split(separator: "\n") {
            let parts = String(line).split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count >= 4, parts[0].hasPrefix("ttys") else { continue }
            let tty = parts[0]; let pid = parts[1]; let comm = parts[2]; let cpu = Double(parts[3]) ?? 0
            if comm == "claude" { ttyCpu[tty] = max(ttyCpu[tty] ?? 0, cpu) }
            if (comm == "zsh" || comm == "bash") && ttyShellPids[tty] == nil { ttyShellPids[tty] = pid }
        }

        guard !ttyCpu.isEmpty else { return [:] }

        // Batch lsof for all shell PIDs on claude TTYs in one call
        let pids = ttyCpu.keys.compactMap { ttyShellPids[$0] }
        guard !pids.isEmpty else { return [:] }

        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-a", "-p", pids.joined(separator: ","), "-d", "cwd", "-Fn"]
        let lsofPipe = Pipe()
        lsof.standardOutput = lsofPipe
        lsof.standardError = Pipe()
        try? lsof.run(); lsof.waitUntilExit()
        let lsofOut = String(data: lsofPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        // Parse pid→cwd from lsof -Fn output (p<pid>\nfcwd\nn<path>)
        var pidCwd: [String: String] = [:]
        var currentPid: String?
        for line in lsofOut.split(separator: "\n") {
            let s = String(line)
            if s.hasPrefix("p") { currentPid = String(s.dropFirst()) }
            else if s.hasPrefix("n"), let pid = currentPid { pidCwd[pid] = String(s.dropFirst()) }
        }

        // Map TTY → folder name
        let prefix = codeDir + "/"
        var sessions: [String: FolderSession] = [:]
        for (tty, cpu) in ttyCpu {
            guard let pid = ttyShellPids[tty], let cwd = pidCwd[pid] else { continue }
            guard cwd.hasPrefix(prefix) else { continue }
            let remainder = String(cwd.dropFirst(prefix.count))
            if let name = remainder.split(separator: "/").first {
                sessions[String(name)] = FolderSession(tty: "/dev/" + tty, status: cpu > 1.0 ? .active : .waiting)
            }
        }
        return sessions
    }

    // MARK: - TTY lookup for a specific folder (reuses batched discovery)

    func findClaudeTTY(for folder: String) -> String? {
        let sessions = runDiscovery()
        DispatchQueue.main.async {
            self.folderSessions = sessions
            self.lastDiscoveryTime = Date()
        }
        return sessions[folder]?.tty
    }

    // MARK: - Verify claude is still the foreground process on a TTY

    func verifyClaudeOnTTY(_ tty: String) -> Bool {
        let ttyShort = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-t", ttyShort, "-o", "comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = Pipe()
        try? ps.run(); ps.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .contains("claude")
    }

    // MARK: - Send text to an iTerm session by TTY

    func kickSession(tty: String, prompt: String, folder: String = "") -> Bool {
        // Verify claude is actually running on this TTY before sending
        guard verifyClaudeOnTTY(tty) else { return false }

        let safe = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let src = """
        tell application "iTerm2"
            repeat with w in every window
                repeat with t in every tab of w
                    repeat with s in every session of t
                        if tty of s is "\(tty)" then
                            tell s
                                select
                                write text "\(safe)"
                            end tell
                            return "Sent"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "NotFound"
        """
        var err: NSDictionary?
        if let result = NSAppleScript(source: src)?.executeAndReturnError(&err) {
            if result.stringValue == "Sent" { return true }
        }
        if let e = err { fputs("kickSession AppleScript error: \(e)\n", stderr) }

        // Fallback: shell-based td kick
        if !folder.isEmpty {
            let safeF = folder.replacingOccurrences(of: "'", with: "'\\''")
            let safeP = prompt.replacingOccurrences(of: "'", with: "'\\''")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-lc", "'\(tdPath)' kick '\(safeF)' '\(safeP)'"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            try? proc.run(); proc.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if out.contains("Sent") { return true }
        }

        return false
    }

    // MARK: - Quick Add

    func showQuickAdd() {
        if let existing = panel, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if selectedFolder != nil { promptField?.selectText(nil) }
            else { folderField?.selectText(nil) }
            return
        }

        let rememberedFolder = selectedFolder
        closeQuickAdd()
        selectedFolder = rememberedFolder

        selectedIndex = -1
        filteredFolders = []

        let shiftHeld = NSEvent.modifierFlags.contains(.shift)
        let useRemembered = selectedFolder != nil && !shiftHeld

        let w: CGFloat = 340
        let h: CGFloat = 52
        var origin = NSPoint(x: 200, y: 200)
        if let buttonFrame = statusItem.button?.window?.frame {
            origin = NSPoint(x: buttonFrame.maxX - w, y: buttonFrame.minY - h - 4)
        }

        let p = KeyPanel(
            contentRect: NSRect(x: origin.x, y: origin.y, width: w, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.level = .popUpMenu
        p.isFloatingPanel = true
        p.hidesOnDeactivate = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false

        let outer = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        outer.wantsLayer = true
        outer.layer?.shadowColor = NSColor.black.cgColor
        outer.layer?.shadowOpacity = 0.3
        outer.layer?.shadowRadius = 8
        outer.layer?.shadowOffset = CGSize(width: 0, height: -2)
        outer.layer?.shadowPath = CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: w, height: h),
            cornerWidth: 10, cornerHeight: 10, transform: nil
        )

        let inner = NSView(frame: outer.bounds)
        inner.wantsLayer = true
        inner.layer?.cornerRadius = 10
        inner.layer?.cornerCurve = .continuous
        inner.layer?.masksToBounds = true
        outer.addSubview(inner)

        let bg = NSVisualEffectView(frame: inner.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.appearance = NSAppearance(named: .darkAqua)
        let bgMask = CAShapeLayer()
        bgMask.path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h),
                             cornerWidth: 10, cornerHeight: 10, transform: nil)
        bg.layer?.mask = bgMask
        inner.addSubview(bg)

        let prefixLabel = NSTextField(frame: NSRect(x: 12, y: h - 24, width: 16, height: 18))
        prefixLabel.stringValue = ">"
        prefixLabel.isEditable = false
        prefixLabel.isSelectable = false
        prefixLabel.isBezeled = false
        prefixLabel.drawsBackground = false
        prefixLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        prefixLabel.textColor = NSColor.secondaryLabelColor
        inner.addSubview(prefixLabel)

        let folderTF = NSTextField(frame: NSRect(x: 24, y: h - 24, width: w - 36, height: 18))
        folderTF.placeholderString = "search folders..."
        folderTF.stringValue = ""
        folderTF.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        folderTF.isBezeled = false
        folderTF.drawsBackground = false
        folderTF.backgroundColor = .clear
        (folderTF.cell as? NSTextFieldCell)?.drawsBackground = false
        folderTF.textColor = .white
        folderTF.focusRingType = .none
        folderTF.delegate = self
        folderTF.tag = 1
        inner.addSubview(folderTF)
        folderField = folderTF

        let promptTF = NSTextField(frame: NSRect(x: 12, y: 6, width: w - 24, height: 20))
        promptTF.placeholderString = "prompt  \u{21A9}"
        promptTF.font = NSFont.systemFont(ofSize: 13)
        promptTF.isBezeled = false
        promptTF.drawsBackground = false
        promptTF.backgroundColor = .clear
        promptTF.maximumNumberOfLines = 1
        promptTF.usesSingleLineMode = true
        (promptTF.cell as? NSTextFieldCell)?.drawsBackground = false
        (promptTF.cell as? NSTextFieldCell)?.isScrollable = true
        (promptTF.cell as? NSTextFieldCell)?.lineBreakMode = .byClipping
        promptTF.textColor = NSColor.tertiaryLabelColor
        promptTF.focusRingType = .none
        promptTF.delegate = self
        promptTF.tag = 2
        promptTF.isEnabled = false
        inner.addSubview(promptTF)

        p.contentView = outer
        panel = p
        promptField = promptTF

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let panel = self.panel, panel.isVisible else { return event }
            if event.keyCode == 36, event.modifierFlags.contains(.command) {
                if let editor = self.promptField?.currentEditor(), editor == panel.firstResponder {
                    self.submitQuickAdd(withGit: true)
                    return nil
                }
            }
            return event
        }

        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Pre-populate remembered folder synchronously for instant UX
        if useRemembered, let remembered = selectedFolder {
            folderTF.stringValue = remembered
            promptTF.isEnabled = true
            promptTF.textColor = .white
            promptTF.becomeFirstResponder()
        } else {
            folderTF.becomeFirstResponder()
        }

        // Async folder scan — validate remembered folder + populate list
        scanFolders { [weak self] folders in
            guard let self = self, self.panel != nil else { return }
            self.allFolders = folders

            // Invalidate remembered folder if it no longer exists on disk
            if let remembered = self.selectedFolder, !folders.contains(remembered) {
                self.selectedFolder = nil
                self.folderField?.stringValue = ""
                self.promptField?.isEnabled = false
                self.promptField?.textColor = .tertiaryLabelColor
                self.folderField?.becomeFirstResponder()
            }
        }

        // Respect TTL before re-discovering sessions
        discoverActiveFolders()
    }

    func closeQuickAdd() {
        hideResults()
        panel?.close()
        panel = nil
        folderField = nil
        promptField = nil
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
    }

    // MARK: - Sorting

    func sortedWithSessions(_ folders: [String]) -> [String] {
        folders.sorted { a, b in
            let aHas = folderSessions[a] != nil
            let bHas = folderSessions[b] != nil
            if aHas != bHas { return aHas }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    // MARK: - Dropdown results

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }

        if field.tag == 2 {
            hideResults()
            let text = field.stringValue
            if text.contains("\n") || text.contains("\r") {
                let flat = text
                    .replacingOccurrences(of: "\r\n", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                field.stringValue = flat
                if let editor = field.currentEditor() {
                    editor.selectedRange = NSRange(location: flat.count, length: 0)
                }
            }
            return
        }

        guard field.tag == 1 else { return }

        if selectedFolder != nil {
            selectedFolder = nil
            promptField?.isEnabled = false
            promptField?.textColor = NSColor.tertiaryLabelColor
        }

        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        let base = query.isEmpty ? allFolders : allFolders.filter { $0.localizedCaseInsensitiveContains(query) }
        filteredFolders = sortedWithSessions(base)
        selectedIndex = filteredFolders.isEmpty ? -1 : 0

        if filteredFolders.isEmpty { hideResults() } else { showResults() }
    }

    func showResults() {
        hideResults()
        guard !filteredFolders.isEmpty, let mainPanel = panel else { return }

        let maxVisible = min(filteredFolders.count, 8)
        let rowH: CGFloat = 22
        let pad: CGFloat = 8
        let dropH = CGFloat(maxVisible) * rowH + pad
        let w = mainPanel.frame.width

        let dp = NSPanel(
            contentRect: NSRect(
                x: mainPanel.frame.minX,
                y: mainPanel.frame.minY - dropH - 2,
                width: w, height: dropH
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        dp.level = .popUpMenu
        dp.isFloatingPanel = true
        dp.hidesOnDeactivate = true
        dp.isOpaque = false
        dp.backgroundColor = .clear
        dp.hasShadow = false

        let outer = NSView(frame: NSRect(x: 0, y: 0, width: w, height: dropH))
        outer.wantsLayer = true
        outer.layer?.shadowColor = NSColor.black.cgColor
        outer.layer?.shadowOpacity = 0.25
        outer.layer?.shadowRadius = 6
        outer.layer?.shadowOffset = CGSize(width: 0, height: -2)
        outer.layer?.shadowPath = CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: w, height: dropH),
            cornerWidth: 10, cornerHeight: 10, transform: nil
        )

        let inner = NSView(frame: outer.bounds)
        inner.wantsLayer = true
        inner.layer?.cornerRadius = 10
        inner.layer?.cornerCurve = .continuous
        inner.layer?.masksToBounds = true
        outer.addSubview(inner)

        let bg = NSVisualEffectView(frame: inner.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.appearance = NSAppearance(named: .darkAqua)
        let bgMask = CAShapeLayer()
        bgMask.path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: dropH),
                             cornerWidth: 10, cornerHeight: 10, transform: nil)
        bg.layer?.mask = bgMask
        inner.addSubview(bg)

        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        resultLabels = []
        for i in 0..<maxVisible {
            let y = dropH - pad / 2 - CGFloat(i + 1) * rowH
            let lbl = NSTextField(frame: NSRect(x: 0, y: y, width: w, height: rowH))
            let name = filteredFolders[i]
            let isHighlighted = (i == selectedIndex)

            let attrStr = NSMutableAttributedString()
            if let session = folderSessions[name] {
                let dotColor: NSColor = session.status == .active ? pastelGreen : pastelYellow
                attrStr.append(NSAttributedString(string: " \u{25CF} ", attributes: [.foregroundColor: dotColor, .font: monoFont]))
            } else {
                attrStr.append(NSAttributedString(string: "   ", attributes: [.font: monoFont]))
            }
            attrStr.append(NSAttributedString(string: name, attributes: [
                .foregroundColor: isHighlighted ? NSColor.white : NSColor.secondaryLabelColor,
                .font: monoFont
            ]))

            lbl.attributedStringValue = attrStr
            lbl.isEditable = false
            lbl.isSelectable = false
            lbl.isBezeled = false
            lbl.drawsBackground = true
            lbl.lineBreakMode = .byTruncatingTail
            lbl.backgroundColor = isHighlighted ? NSColor.white.withAlphaComponent(0.15) : .clear

            let click = NSClickGestureRecognizer(target: self, action: #selector(resultClicked(_:)))
            lbl.addGestureRecognizer(click)
            lbl.tag = i

            inner.addSubview(lbl)
            resultLabels.append(lbl)
        }

        dp.contentView = outer
        resultsPanel = dp
        mainPanel.addChildWindow(dp, ordered: .below)
        dp.orderFront(nil)
    }

    func hideResults() {
        if let dp = resultsPanel { panel?.removeChildWindow(dp); dp.close() }
        resultsPanel = nil
        resultLabels = []
    }

    @objc func resultClicked(_ gesture: NSClickGestureRecognizer) {
        guard let lbl = gesture.view as? NSTextField else { return }
        selectedIndex = lbl.tag
        selectFolder()
    }

    func selectFolder() {
        guard selectedIndex >= 0, selectedIndex < filteredFolders.count else { return }
        selectedFolder = filteredFolders[selectedIndex]
        folderField?.stringValue = selectedFolder!
        hideResults()
        promptField?.isEnabled = true
        promptField?.textColor = .white
        panel?.makeKeyAndOrderFront(nil)
        promptField?.becomeFirstResponder()
    }

    func updateHighlight() {
        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        for (i, lbl) in resultLabels.enumerated() {
            guard i < filteredFolders.count else { continue }
            let name = filteredFolders[i]
            let isHighlighted = (i == selectedIndex)

            let attrStr = NSMutableAttributedString()
            if let session = folderSessions[name] {
                let dotColor: NSColor = session.status == .active ? pastelGreen : pastelYellow
                attrStr.append(NSAttributedString(string: " \u{25CF} ", attributes: [.foregroundColor: dotColor, .font: monoFont]))
            } else {
                attrStr.append(NSAttributedString(string: "   ", attributes: [.font: monoFont]))
            }
            attrStr.append(NSAttributedString(string: name, attributes: [
                .foregroundColor: isHighlighted ? NSColor.white : NSColor.secondaryLabelColor,
                .font: monoFont
            ]))

            lbl.attributedStringValue = attrStr
            lbl.backgroundColor = isHighlighted ? NSColor.white.withAlphaComponent(0.15) : .clear
        }
    }

    // MARK: - Key handling

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        let isFolder = (control as? NSTextField)?.tag == 1
        let isPrompt = (control as? NSTextField)?.tag == 2

        if sel == #selector(NSResponder.cancelOperation(_:)) {
            closeQuickAdd()
            return true
        }

        if sel == #selector(NSResponder.insertNewline(_:)) {
            if isFolder {
                let typed = folderField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
                if typed.isEmpty {
                    selectedFolder = nil
                    hideResults()
                    promptField?.isEnabled = true
                    promptField?.textColor = .white
                    promptField?.placeholderString = "prompt (fresh session)  \u{21A9}"
                    promptField?.becomeFirstResponder()
                } else if selectedIndex >= 0, selectedIndex < filteredFolders.count {
                    selectFolder()
                } else if !allFolders.contains(typed) {
                    let path = (codeDir as NSString).appendingPathComponent(typed)
                    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                    allFolders.append(typed)
                    allFolders.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                    selectedFolder = typed
                    folderField?.stringValue = typed
                    hideResults()
                    promptField?.isEnabled = true
                    promptField?.textColor = .white
                    promptField?.becomeFirstResponder()
                }
                return true
            }
            if isPrompt { submitQuickAdd(withGit: false); return true }
        }

        if sel == #selector(NSResponder.insertTab(_:)) {
            if isPrompt {
                panel?.makeKeyAndOrderFront(nil)
                folderField?.becomeFirstResponder()
                folderField?.selectText(nil)
                return true
            }
            if isFolder {
                let typed = folderField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
                if selectedFolder != nil {
                    hideResults()
                    promptField?.becomeFirstResponder()
                } else if typed.isEmpty {
                    selectedFolder = nil
                    hideResults()
                    promptField?.isEnabled = true
                    promptField?.textColor = .white
                    promptField?.placeholderString = "prompt (fresh session)  \u{21A9}"
                    promptField?.becomeFirstResponder()
                } else if selectedIndex >= 0, selectedIndex < filteredFolders.count {
                    selectFolder()
                }
                return true
            }
        }

        if isFolder {
            if sel == #selector(NSResponder.moveDown(_:)) {
                if filteredFolders.isEmpty && !allFolders.isEmpty {
                    filteredFolders = sortedWithSessions(allFolders)
                    selectedIndex = 0
                    showResults()
                } else if !filteredFolders.isEmpty {
                    selectedIndex = min(selectedIndex + 1, min(filteredFolders.count, 8) - 1)
                    updateHighlight()
                }
                return true
            }
            if sel == #selector(NSResponder.moveUp(_:)) {
                if !filteredFolders.isEmpty {
                    selectedIndex = max(selectedIndex - 1, 0)
                    updateHighlight()
                }
                return true
            }
        }

        return false
    }

    // MARK: - Submit

    func submitQuickAdd(withGit: Bool = false) {
        let folder = selectedFolder
        let prompt = promptField?.stringValue ?? ""
        closeQuickAdd()

        guard let folder = folder else {
            startClaude(path: nil, prompt: prompt, withGit: withGit)
            flash()
            return
        }

        let path = (codeDir as NSString).appendingPathComponent(folder)

        if !prompt.isEmpty {
            let cachedTTY = folderSessions[folder]?.tty

            let doKick = { [weak self] in
                guard let self = self else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    var kicked = false

                    if let tty = cachedTTY {
                        kicked = self.kickSession(tty: tty, prompt: prompt, folder: folder)
                    }
                    if !kicked, let freshTTY = self.findClaudeTTY(for: folder) {
                        kicked = self.kickSession(tty: freshTTY, prompt: prompt, folder: folder)
                    }

                    DispatchQueue.main.async {
                        if kicked { self.flash() }
                        else { self.startClaude(path: path, prompt: prompt, withGit: withGit); self.flash() }
                    }
                }
            }

            // Wait for in-progress scan (up to 500ms) before kicking
            if isScanning {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { doKick() }
            } else {
                doKick()
            }
            return
        }

        startClaude(path: path, prompt: prompt, withGit: withGit)
        flash()
    }

    func startClaude(path: String?, prompt: String, withGit: Bool = false) {
        let safePrompt = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        var cmd: String
        if let path = path {
            let safePath = path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            cmd = "ulimit -n 65536 ; cd \\\"\(safePath)\\\""
            if withGit {
                cmd += " && git log --oneline --graph -20 ; claude --dangerously-skip-permissions"
            } else {
                cmd += " && claude --dangerously-skip-permissions"
            }
        } else {
            cmd = "ulimit -n 65536 ; claude --dangerously-skip-permissions"
        }
        if !prompt.isEmpty { cmd += " \\\"\(safePrompt)\\\"" }

        let src = """
        tell application "iTerm2"
            set newWindow to (create window with default profile)
            tell current session of current tab of newWindow
                write text "\(cmd)"
            end tell
            activate
        end tell
        """
        // Dispatch off main thread — AppleScript/iTerm2 IPC can take 100–500ms
        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
            if let e = err { fputs("startClaude AppleScript error: \(e)\n", stderr) }
        }
    }

    // MARK: - Menu

    func showMenu() {
        let menu = NSMenu()
        menu.minimumWidth = 140

        item(menu, "Quick Add", "n", #selector(openQuickAdd))
        item(menu, "Tile Up",   "t", #selector(tile))
        menu.addItem(NSMenuItem.separator())
        item(menu, "Quit",      "q", #selector(quit))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func item(_ menu: NSMenu, _ title: String, _ key: String, _ action: Selector) {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        menu.addItem(mi)
    }

    @objc func tile()         { run("tile"); flash() }
    @objc func openQuickAdd() { showQuickAdd() }
    @objc func quit()         { NSApp.terminate(nil) }

    func run(_ cmd: String) {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/bin/zsh")
        t.arguments = ["-lc", "\(tdPath) \(cmd)"]
        try? t.run()
    }

    func flash() {
        guard let button = statusItem.button else { return }
        let gridIcon  = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "td")
        gridIcon?.size  = NSSize(width: 16, height: 16)
        let checkIcon = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "done")
        checkIcon?.size = NSSize(width: 16, height: 16)

        button.image = checkIcon
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { button.image = gridIcon }
    }
}

let app = NSApplication.shared
let delegate = TD()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
