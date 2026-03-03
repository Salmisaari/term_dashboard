import Cocoa

class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// Session status for traffic-light indicators
enum SessionStatus { case active, waiting }
struct FolderSession {
    let tty: String      // e.g. "/dev/ttys004"
    let status: SessionStatus
}

class TD: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    var statusItem: NSStatusItem!
    var autoTile = false
    let tdPath: String = {
        let bundle = Bundle.main.bundlePath  // .../menubar/TD.app
        let menubar = (bundle as NSString).deletingLastPathComponent  // .../menubar
        let root = (menubar as NSString).deletingLastPathComponent  // .../term_dashboard
        return (root as NSString).appendingPathComponent("td")
    }()

    var lastClickTime: Date?
    let doubleClickInterval: TimeInterval = 0.3
    var singleClickTimer: Timer?
    var tileDebounce: Timer?
    var lastCapsTime: Date?
    let capsDoubleTap: TimeInterval = 0.35
    var globalFlagsMonitor: Any?
    var localFlagsMonitor: Any?

    // Quick Add — dynamic folder browser
    var panel: KeyPanel?
    var folderField: NSTextField?
    var promptField: NSTextField?
    var resultsPanel: NSPanel?
    var resultLabels: [NSTextField] = []
    var allFolders: [String] = []
    var filteredFolders: [String] = []
    var selectedIndex: Int = -1
    var selectedFolder: String?                     // persists across opens
    var folderSessions: [String: FolderSession] = [:]  // live session status + TTY
    let codeDir = NSString(string: "~/Desktop/Code").expandingTildeInPath
    var keyMonitor: Any?

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
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
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
    }

    func handleCapsLock(_ event: NSEvent) {
        guard event.keyCode == 57 else { return }  // Caps Lock keyCode
        // Ignore if Quick Add panel is already open
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
        // Debounce: multiple observers fire for same space switch — only tile once
        tileDebounce?.invalidate()
        tileDebounce = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { _ in
            if let p = self.panel, p.isVisible { return }
            self.run("tile")
            self.flash()
        }
    }

    // MARK: - Click handling
    // Single click = Quick Add, Double click = Menu

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

    // MARK: - Folder scanning

    func scanFolders() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: codeDir) else {
            allFolders = []
            return
        }
        allFolders = items.filter { name in
            var isDir: ObjCBool = false
            let full = (codeDir as NSString).appendingPathComponent(name)
            return fm.fileExists(atPath: full, isDirectory: &isDir) && isDir.boolValue && !name.hasPrefix(".")
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Active session discovery (ps + lsof, no AppleScript)

    func discoverActiveFolders() {
        DispatchQueue.global(qos: .userInitiated).async {
            // Step 1: Find TTYs with "claude" process + CPU usage
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-eo", "tty,comm,%cpu"]
            let psPipe = Pipe()
            ps.standardOutput = psPipe
            ps.standardError = Pipe()
            try? ps.run()
            ps.waitUntilExit()

            let psData = psPipe.fileHandleForReading.readDataToEndOfFile()
            let psOut = String(data: psData, encoding: .utf8) ?? ""

            // Group by TTY, take max CPU across claude processes on same TTY
            var ttyCpu: [String: Double] = [:]
            for line in psOut.split(separator: "\n") {
                let parts = String(line).split(whereSeparator: { $0.isWhitespace }).map(String.init)
                guard parts.count >= 3, parts[1] == "claude", parts[0].hasPrefix("ttys") else { continue }
                let tty = parts[0]
                let cpu = Double(parts[2]) ?? 0
                ttyCpu[tty] = max(ttyCpu[tty] ?? 0, cpu)
            }

            guard !ttyCpu.isEmpty else {
                DispatchQueue.main.async { self.folderSessions = [:] }
                return
            }

            // Step 2: For each TTY, find shell CWD and map to folder
            var sessions: [String: FolderSession] = [:]
            let prefix = self.codeDir + "/"

            for (tty, cpu) in ttyCpu {
                // Find shell PID on this TTY
                let sh = Process()
                sh.executableURL = URL(fileURLWithPath: "/bin/ps")
                sh.arguments = ["-t", tty, "-o", "pid=,comm="]
                let shPipe = Pipe()
                sh.standardOutput = shPipe
                sh.standardError = Pipe()
                try? sh.run()
                sh.waitUntilExit()

                let shOut = String(data: shPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                var shellPid: String?
                for line in shOut.split(separator: "\n") {
                    let s = String(line).trimmingCharacters(in: .whitespaces)
                    if s.contains("zsh") || s.contains("bash") {
                        shellPid = s.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
                        break
                    }
                }
                guard let pid = shellPid else { continue }

                // Get CWD via lsof
                let lsof = Process()
                lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
                lsof.arguments = ["-a", "-p", pid, "-d", "cwd", "-Fn"]
                let lsofPipe = Pipe()
                lsof.standardOutput = lsofPipe
                lsof.standardError = Pipe()
                try? lsof.run()
                lsof.waitUntilExit()

                let lsofOut = String(data: lsofPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                for line in lsofOut.split(separator: "\n") {
                    let s = String(line)
                    guard s.hasPrefix("n") else { continue }
                    let path = String(s.dropFirst())
                    guard path.hasPrefix(prefix) else { continue }
                    let remainder = String(path.dropFirst(prefix.count))
                    if let name = remainder.split(separator: "/").first {
                        let folder = String(name)
                        let status: SessionStatus = cpu > 1.0 ? .active : .waiting
                        sessions[folder] = FolderSession(tty: "/dev/" + tty, status: status)
                    }
                }
            }

            DispatchQueue.main.async {
                self.folderSessions = sessions
                if self.resultsPanel?.isVisible == true {
                    self.showResults()
                }
            }
        }
    }

    /// Synchronous TTY lookup for a folder — used at kick time for freshness
    func findClaudeTTY(for folder: String) -> String? {
        let targetPath = (codeDir as NSString).appendingPathComponent(folder)

        // Find TTYs with claude
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-eo", "tty,comm"]
        let psPipe = Pipe()
        ps.standardOutput = psPipe
        ps.standardError = Pipe()
        try? ps.run()
        ps.waitUntilExit()

        let psOut = String(data: psPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var claudeTTYs: [String] = []
        for line in psOut.split(separator: "\n") {
            let parts = String(line).split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count >= 2, parts[1] == "claude", parts[0].hasPrefix("ttys") else { continue }
            claudeTTYs.append(parts[0])
        }

        for tty in claudeTTYs {
            let sh = Process()
            sh.executableURL = URL(fileURLWithPath: "/bin/ps")
            sh.arguments = ["-t", tty, "-o", "pid=,comm="]
            let shPipe = Pipe()
            sh.standardOutput = shPipe
            sh.standardError = Pipe()
            try? sh.run()
            sh.waitUntilExit()

            let shOut = String(data: shPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            var shellPid: String?
            for line in shOut.split(separator: "\n") {
                let s = String(line).trimmingCharacters(in: .whitespaces)
                if s.contains("zsh") || s.contains("bash") {
                    shellPid = s.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
                    break
                }
            }
            guard let pid = shellPid else { continue }

            let lsof = Process()
            lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            lsof.arguments = ["-a", "-p", pid, "-d", "cwd", "-Fn"]
            let lsofPipe = Pipe()
            lsof.standardOutput = lsofPipe
            lsof.standardError = Pipe()
            try? lsof.run()
            lsof.waitUntilExit()

            let lsofOut = String(data: lsofPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            for line in lsofOut.split(separator: "\n") {
                let s = String(line)
                guard s.hasPrefix("n") else { continue }
                let cwd = String(s.dropFirst())
                if cwd == targetPath || cwd.hasPrefix(targetPath + "/") {
                    return "/dev/" + tty
                }
            }
        }
        return nil
    }

    /// Send text to an iTerm session by TTY path — tries NSAppleScript first, shell fallback
    func kickSession(tty: String, prompt: String, folder: String = "") -> Bool {
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

        // Fallback: shell-based td kick (uses osascript subprocess)
        if !folder.isEmpty {
            let safeF = folder.replacingOccurrences(of: "'", with: "'\\''")
            let safeP = prompt.replacingOccurrences(of: "'", with: "'\\''")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-lc", "'\(tdPath)' kick '\(safeF)' '\(safeP)'"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            try? proc.run()
            proc.waitUntilExit()
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
            if selectedFolder != nil {
                promptField?.selectText(nil)
            } else {
                folderField?.selectText(nil)
            }
            return
        }

        // Clean up panel UI but preserve selectedFolder
        let rememberedFolder = selectedFolder
        closeQuickAdd()
        selectedFolder = rememberedFolder

        scanFolders()
        selectedIndex = -1
        filteredFolders = []

        // Shift held → force folder picker even if folder is remembered
        let shiftHeld = NSEvent.modifierFlags.contains(.shift)
        let useRemembered = selectedFolder != nil && !shiftHeld

        let w: CGFloat = 340
        let h: CGFloat = 52
        var origin = NSPoint(x: 200, y: 200)
        if let buttonFrame = statusItem.button?.window?.frame {
            origin = NSPoint(
                x: buttonFrame.maxX - w,
                y: buttonFrame.minY - h - 4
            )
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
        inner.layer?.masksToBounds = true
        outer.addSubview(inner)

        let bg = NSVisualEffectView(frame: inner.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.appearance = NSAppearance(named: .darkAqua)
        inner.addSubview(bg)

        // "> " prefix label
        let prefix = NSTextField(frame: NSRect(x: 12, y: h - 24, width: 16, height: 18))
        prefix.stringValue = ">"
        prefix.isEditable = false
        prefix.isSelectable = false
        prefix.isBezeled = false
        prefix.drawsBackground = false
        prefix.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        prefix.textColor = NSColor.secondaryLabelColor
        inner.addSubview(prefix)

        // Folder search field
        let folder = NSTextField(frame: NSRect(x: 24, y: h - 24, width: w - 36, height: 18))
        folder.placeholderString = "search folders..."
        folder.stringValue = ""
        folder.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        folder.isBezeled = false
        folder.drawsBackground = false
        folder.backgroundColor = .clear
        (folder.cell as? NSTextFieldCell)?.drawsBackground = false
        folder.textColor = .white
        folder.focusRingType = .none
        folder.delegate = self
        folder.tag = 1
        inner.addSubview(folder)
        folderField = folder

        // Prompt field (grayed until folder picked)
        let field = NSTextField(frame: NSRect(x: 12, y: 6, width: w - 24, height: 20))
        field.placeholderString = "prompt  \u{21A9}"
        field.font = NSFont.systemFont(ofSize: 13)
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.maximumNumberOfLines = 1
        field.usesSingleLineMode = true
        (field.cell as? NSTextFieldCell)?.drawsBackground = false
        (field.cell as? NSTextFieldCell)?.isScrollable = true
        (field.cell as? NSTextFieldCell)?.lineBreakMode = .byClipping
        field.textColor = NSColor.tertiaryLabelColor
        field.focusRingType = .none
        field.delegate = self
        field.tag = 2
        field.isEnabled = false
        inner.addSubview(field)

        p.contentView = outer
        panel = p
        promptField = field

        // Monitor ⌘+Enter for git-tree mode
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let panel = self.panel, panel.isVisible else { return event }
            if event.keyCode == 36, event.modifierFlags.contains(.command) {
                if let editor = self.promptField?.currentEditor(),
                   editor == panel.firstResponder {
                    self.submitQuickAdd(withGit: true)
                    return nil
                }
            }
            return event
        }

        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Remembered folder → show it, focus prompt directly
        if useRemembered, let remembered = selectedFolder {
            folder.stringValue = remembered
            field.isEnabled = true
            field.textColor = .white
            field.becomeFirstResponder()
        } else {
            selectedFolder = nil
            folder.becomeFirstResponder()
        }

        // Discover active Claude sessions in background
        discoverActiveFolders()
    }

    func closeQuickAdd() {
        hideResults()
        panel?.close()
        panel = nil
        folderField = nil
        promptField = nil
        // selectedFolder persists across opens — remembered for next time
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - Sorting helper

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

        // Typing/pasting in prompt → close dropdown, flatten newlines
        if field.tag == 2 {
            hideResults()
            let text = field.stringValue
            if text.contains("\n") || text.contains("\r") {
                let flat = text.replacingOccurrences(of: "\r\n", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                field.stringValue = flat
                // Move cursor to end
                if let editor = field.currentEditor() {
                    editor.selectedRange = NSRange(location: flat.count, length: 0)
                }
            }
            return
        }

        guard field.tag == 1 else { return }

        // User is re-typing — reset folder selection
        if selectedFolder != nil {
            selectedFolder = nil
            promptField?.isEnabled = false
            promptField?.textColor = NSColor.tertiaryLabelColor
        }

        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        let base: [String]
        if query.isEmpty {
            base = allFolders
        } else {
            base = allFolders.filter {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
        filteredFolders = sortedWithSessions(base)
        selectedIndex = filteredFolders.isEmpty ? -1 : 0

        if filteredFolders.isEmpty {
            hideResults()
        } else {
            showResults()
        }
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
                width: w,
                height: dropH
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
        inner.layer?.masksToBounds = true
        outer.addSubview(inner)

        let bg = NSVisualEffectView(frame: inner.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.appearance = NSAppearance(named: .darkAqua)
        inner.addSubview(bg)

        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        resultLabels = []
        for i in 0..<maxVisible {
            let y = dropH - pad / 2 - CGFloat(i + 1) * rowH
            let lbl = NSTextField(frame: NSRect(x: 0, y: y, width: w, height: rowH))
            let name = filteredFolders[i]
            let isHighlighted = (i == selectedIndex)
            let textColor: NSColor = isHighlighted ? .white : NSColor.secondaryLabelColor

            // Build attributed string with pastel traffic-light dot
            let attrStr = NSMutableAttributedString()
            if let session = folderSessions[name] {
                let dotColor: NSColor = session.status == .active ? pastelGreen : pastelYellow
                attrStr.append(NSAttributedString(string: " \u{25CF} ", attributes: [
                    .foregroundColor: dotColor,
                    .font: monoFont
                ]))
            } else {
                attrStr.append(NSAttributedString(string: "   ", attributes: [.font: monoFont]))
            }
            attrStr.append(NSAttributedString(string: name, attributes: [
                .foregroundColor: textColor,
                .font: monoFont
            ]))

            lbl.attributedStringValue = attrStr
            lbl.isEditable = false
            lbl.isSelectable = false
            lbl.isBezeled = false
            lbl.drawsBackground = true
            lbl.lineBreakMode = .byTruncatingTail

            if isHighlighted {
                lbl.backgroundColor = NSColor.white.withAlphaComponent(0.15)
            } else {
                lbl.backgroundColor = .clear
            }

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
        if let dp = resultsPanel {
            panel?.removeChildWindow(dp)
            dp.close()
        }
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
            let textColor: NSColor = isHighlighted ? .white : NSColor.secondaryLabelColor

            let attrStr = NSMutableAttributedString()
            if let session = folderSessions[name] {
                let dotColor: NSColor = session.status == .active ? pastelGreen : pastelYellow
                attrStr.append(NSAttributedString(string: " \u{25CF} ", attributes: [
                    .foregroundColor: dotColor,
                    .font: monoFont
                ]))
            } else {
                attrStr.append(NSAttributedString(string: "   ", attributes: [.font: monoFont]))
            }
            attrStr.append(NSAttributedString(string: name, attributes: [
                .foregroundColor: textColor,
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

        // Escape → close everything
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            closeQuickAdd()
            return true
        }

        // Enter
        if sel == #selector(NSResponder.insertNewline(_:)) {
            if isFolder {
                let typed = folderField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
                if typed.isEmpty {
                    // No folder — fresh session
                    selectedFolder = nil
                    hideResults()
                    promptField?.isEnabled = true
                    promptField?.textColor = .white
                    promptField?.placeholderString = "prompt (fresh session)  \u{21A9}"
                    promptField?.becomeFirstResponder()
                } else if selectedIndex >= 0, selectedIndex < filteredFolders.count {
                    selectFolder()
                } else if !allFolders.contains(typed) {
                    // New folder — create it
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
            if isPrompt {
                submitQuickAdd(withGit: false)
                return true
            }
        }

        // Tab
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
                    // Empty → fresh session
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

        // Arrow keys in folder field → navigate dropdown
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

        // No folder — fresh Claude session
        guard let folder = folder else {
            startClaude(path: nil, prompt: prompt, withGit: withGit)
            flash()
            return
        }

        let path = (codeDir as NSString).appendingPathComponent(folder)

        // Try to kick to existing Claude session (direct NSAppleScript — no subprocess)
        if !prompt.isEmpty {
            // Use cached TTY first, fall back to fresh lookup
            let cachedTTY = folderSessions[folder]?.tty

            DispatchQueue.global(qos: .userInitiated).async {
                var kicked = false

                // Try cached TTY
                if let tty = cachedTTY {
                    DispatchQueue.main.sync { kicked = self.kickSession(tty: tty, prompt: prompt, folder: folder) }
                }

                // If cached failed, try fresh lookup
                if !kicked {
                    if let freshTTY = self.findClaudeTTY(for: folder) {
                        DispatchQueue.main.sync { kicked = self.kickSession(tty: freshTTY, prompt: prompt, folder: folder) }
                    }
                }

                DispatchQueue.main.async {
                    if kicked {
                        self.flash()
                    } else {
                        self.startClaude(path: path, prompt: prompt, withGit: withGit)
                        self.flash()
                    }
                }
            }
            return
        }

        // No prompt: just open new iTerm + claude
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
            cmd = "cd \\\"\(safePath)\\\""
            if withGit {
                cmd += " && git log --oneline --graph -20 ; claude --dangerously-skip-permissions"
            } else {
                cmd += " && claude --dangerously-skip-permissions"
            }
        } else {
            cmd = "claude --dangerously-skip-permissions"
        }
        if !prompt.isEmpty {
            cmd += " \\\"\(safePrompt)\\\""
        }

        let src = """
        tell application "iTerm2"
            set newWindow to (create window with default profile)
            tell current session of current tab of newWindow
                write text "\(cmd)"
            end tell
            activate
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
    }

    // MARK: - Menu

    func showMenu() {
        let menu = NSMenu()
        menu.minimumWidth = 140

        item(menu, "Quick Add",  "n", #selector(openQuickAdd))
        item(menu, "Tile Up",   "t", #selector(tile))
        menu.addItem(NSMenuItem.separator())
        item(menu, "Quit",      "q", #selector(quit))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Synchronous session refresh (used by Quick Add dropdown)
    func refreshSessionsSync() {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-eo", "tty,comm,%cpu"]
        let psPipe = Pipe()
        ps.standardOutput = psPipe
        ps.standardError = Pipe()
        try? ps.run()
        ps.waitUntilExit()

        let psOut = String(data: psPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var ttyCpu: [String: Double] = [:]
        for line in psOut.split(separator: "\n") {
            let parts = String(line).split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count >= 3, parts[1] == "claude", parts[0].hasPrefix("ttys") else { continue }
            let tty = parts[0]
            let cpu = Double(parts[2]) ?? 0
            ttyCpu[tty] = max(ttyCpu[tty] ?? 0, cpu)
        }

        var sessions: [String: FolderSession] = [:]
        let prefix = codeDir + "/"

        for (tty, cpu) in ttyCpu {
            let sh = Process()
            sh.executableURL = URL(fileURLWithPath: "/bin/ps")
            sh.arguments = ["-t", tty, "-o", "pid=,comm="]
            let shPipe = Pipe()
            sh.standardOutput = shPipe
            sh.standardError = Pipe()
            try? sh.run()
            sh.waitUntilExit()

            let shOut = String(data: shPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            var shellPid: String?
            for line in shOut.split(separator: "\n") {
                let s = String(line).trimmingCharacters(in: .whitespaces)
                if s.contains("zsh") || s.contains("bash") {
                    shellPid = s.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
                    break
                }
            }
            guard let pid = shellPid else { continue }

            let lsof = Process()
            lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            lsof.arguments = ["-a", "-p", pid, "-d", "cwd", "-Fn"]
            let lsofPipe = Pipe()
            lsof.standardOutput = lsofPipe
            lsof.standardError = Pipe()
            try? lsof.run()
            lsof.waitUntilExit()

            let lsofOut = String(data: lsofPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            for line in lsofOut.split(separator: "\n") {
                let s = String(line)
                guard s.hasPrefix("n") else { continue }
                let path = String(s.dropFirst())
                guard path.hasPrefix(prefix) else { continue }
                let remainder = String(path.dropFirst(prefix.count))
                if let name = remainder.split(separator: "/").first {
                    let folder = String(name)
                    let status: SessionStatus = cpu > 1.0 ? .active : .waiting
                    sessions[folder] = FolderSession(tty: "/dev/" + tty, status: status)
                }
            }
        }
        folderSessions = sessions
    }

    func item(_ menu: NSMenu, _ title: String, _ key: String, _ action: Selector) {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        menu.addItem(mi)
    }

    @objc func tile()        { run("tile"); flash() }
    @objc func openQuickAdd(){ showQuickAdd() }
    @objc func quit()        { NSApp.terminate(nil) }

    func run(_ cmd: String) {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/bin/zsh")
        t.arguments = ["-lc", "\(tdPath) \(cmd)"]
        try? t.run()
    }

    func flash() {
        guard let button = statusItem.button else { return }
        let gridIcon = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "td")
        gridIcon?.size = NSSize(width: 16, height: 16)
        let checkIcon = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "done")
        checkIcon?.size = NSSize(width: 16, height: 16)

        button.image = checkIcon
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            button.image = gridIcon
        }
    }
}

let app = NSApplication.shared
let delegate = TD()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
