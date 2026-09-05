// Native TD workspace. The menu bar owns the human loop; Python owns terminal identity/state.
import Cocoa
import Carbon

typealias Record = [String: Any]
extension Dictionary where Key == String, Value == Any {
    func text(_ key: String, _ fallback: String = "") -> String { self[key] as? String ?? fallback }
    func flag(_ key: String) -> Bool { self[key] as? Bool ?? false }
    func number(_ key: String) -> Double { (self[key] as? NSNumber)?.doubleValue ?? 0 }
    func record(_ key: String) -> Record { self[key] as? Record ?? [:] }
    func records(_ key: String) -> [Record] { self[key] as? [Record] ?? [] }
}
final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }
final class Canvas: NSView { override var isFlipped: Bool { true } }
final class ActionButton: NSButton {
    var invoke: (() -> Void)?
    init(_ title: String, frame: NSRect, action: @escaping () -> Void) {
        super.init(frame: frame); self.title = title; self.invoke = action
        target = self; self.action = #selector(fire); isBordered = false
        font = .systemFont(ofSize: 11, weight: .medium); contentTintColor = .secondaryLabelColor
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func fire() { invoke?() }
}
final class SessionRow: NSButton {
    override var isFlipped: Bool { true }
    let session: Record
    var invoke: (() -> Void)?
    init(_ session: Record, y: CGFloat, width: CGFloat, selected: Bool, action: @escaping () -> Void) {
        self.session = session
        super.init(frame: NSRect(x: 8, y: y, width: width - 16, height: 52))
        invoke = action; target = self; self.action = #selector(fire); title = ""; isBordered = false
        wantsLayer = true; layer?.cornerRadius = 8
        if selected { layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor }
        setAccessibilityLabel("\(session.text("project")), \(session.text("provider")), \(session.text("tty")), \(statusName(session))")
        toolTip = session.text("cwd") + "\n" + session.text("id")
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func fire() { invoke?() }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let dot = NSBezierPath(ovalIn: NSRect(x: 10, y: 16, width: 6, height: 6))
        statusColor(session).setFill(); dot.fill()
        let name = session.text("project") + (session.flag("pinned") ? "  · held" : "")
        drawText(name, rect: NSRect(x: 26, y: 9, width: bounds.width - 134, height: 20), size: 12, color: .labelColor, weight: .medium)
        drawText(session.text("provider"), rect: NSRect(x: bounds.width-105, y: 11, width: 83, height: 18), size: 10, color: .secondaryLabelColor, alignment: .right)
        let tty = session.text("tty").replacingOccurrences(of: "/dev/", with: "")
        let subtitle = tty + " · " + (session.flag("needs_attention") ? session.text("summary") : statusName(session))
        drawText(subtitle, rect: NSRect(x: 26, y: 29, width: bounds.width-49, height: 17), size: 10, color: .secondaryLabelColor)
        drawText("›", rect: NSRect(x: bounds.width-19, y: 8, width: 12, height: 20), size: 16, color: .tertiaryLabelColor)
    }
}
func drawText(_ text: String, rect: NSRect, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular, alignment: NSTextAlignment = .left) {
    let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail; style.alignment = alignment
    (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style])
}
let accent = NSColor(calibratedRed: 0.68, green: 0.85, blue: 0.73, alpha: 1)
func statusColor(_ s: Record) -> NSColor {
    if s.flag("stale") { return .systemOrange }
    switch s.text("status") {
    case "blocked": return NSColor(calibratedRed: 0.90, green: 0.65, blue: 0.52, alpha: 1)
    case "waiting": return NSColor(calibratedRed: 0.87, green: 0.78, blue: 0.52, alpha: 1)
    case "done": return accent
    default: return .secondaryLabelColor
    }
}
func statusName(_ s: Record) -> String {
    if s.flag("stale") { return "Last seen · reconnecting" }
    if s["report_at"] is NSNumber { return ["running":"Working", "waiting":"Your turn", "blocked":"Needs a decision", "done":"Done · reported"][s.text("status")] ?? "Open" }
    return s.text("provider") == "shell" ? "Shell open" : "Agent open · no update yet"
}

final class TD: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    let width: CGFloat = 400
    let demo = CommandLine.arguments.contains("--demo")
    let snapshotMode = CommandLine.arguments.contains("--snapshot")
    lazy var defaults = demo ? UserDefaults(suiteName: "com.td.menubar.demo")! : UserDefaults.standard
    var statusItem: NSStatusItem!
    var panel: KeyPanel!
    var canvas: Canvas!
    var body: Canvas!
    var folderField: NSTextField!
    var composer: NSTextView!
    var composerScroll: NSScrollView!
    var countButton: ActionButton!
    var providerButton: ActionButton!
    var awakeButton: ActionButton!
    var mode = "new"
    var expanded = false
    var detailsVisible = false
    var selectedID: String?
    var folder = ""
    var provider = "codex"
    var query = ""
    var state: Record = [:]
    var pending = false
    var receipt = ""
    var receiptDate = Date.distantPast
    var lastRefresh = Date.distantPast
    var error = ""
    var inspection: String?
    var detailTextScroll: NSScrollView?
    var selectedProposal: String?
    var drafts: [String: String] = [:]
    var scrollOffset: CGFloat = 0
    var lastCaps = Date.distantPast
    var globalMonitor: Any?
    var localMonitor: Any?
    var keyMonitor: Any?
    var outsideMonitor: Any?
    var timer: Timer?
    var autoTile = false
    var keyboardIndex = 0
    var activeRequest = UUID()
    var didRespond: ((String) -> Void)?
    var missingAccess: [(String, String)] = []
    let queue = DispatchQueue(label: "td.native.bridge", qos: .userInitiated)
    var sessions: [Record] { state.records("sessions") }
    var selected: Record? { sessions.first { $0.text("id") == selectedID } }
    var draftKey: String { selectedID ?? "new:" + folder }
    var headerHeight: CGFloat {
        guard let composer = composer, let manager = composer.layoutManager, let container = composer.textContainer else { return 52 }
        manager.ensureLayout(for: container)
        let lineHeight = manager.defaultLineHeight(for: composer.font ?? .systemFont(ofSize: 13))
        let wrapped = Int(ceil(manager.usedRect(for: container).height / lineHeight))
        let explicit = composer.string.split(separator: "\n", omittingEmptySubsequences: false).count
        let lines = max(1, min(5, max(wrapped, explicit)))
        return 52 + CGFloat(lines-1)*17
    }
    var tdPath: String {
        if let explicit = ProcessInfo.processInfo.environment["TD_EXECUTABLE"] { return explicit }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("td").path,
           FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return (NSHomeDirectory() + "/bin/td" as NSString).resolvingSymlinksInPath
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        provider = defaults.string(forKey: "workspace.provider") ?? defaults.string(forKey: "td.selectedLaunchAgent") ?? "codex"
        folder = defaults.string(forKey: "workspace.folder") ?? ""
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "TD terminals")
            b.imagePosition = .imageLeading; b.target = self; b.action = #selector(statusClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp]); b.toolTip = "TD · your terminals, held here"
        }
        let menu = NSMenu(); let edit = NSMenu(); let item = NSMenuItem(); item.submenu = edit
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        menu.addItem(item); NSApp.mainMenu = menu
        makePanel()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] in self?.caps($0) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in self?.caps(event); return event }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.panel.isVisible else { return }
            self.panel.orderOut(nil)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.panel.isKeyWindow else { return event }
            if event.keyCode == 53 {
                self.goBack()
                return nil
            }
            if event.modifierFlags.contains(.command) {
                if event.charactersIgnoringModifiers == "l" { self.expand("sessions"); self.folderField.selectText(nil); return nil }
                if event.charactersIgnoringModifiers == "n" { self.newSession(); return nil }
                if event.charactersIgnoringModifiers == "r" { self.fetch(force: true); return nil }
            }
            return event
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.panel.isVisible || Date().timeIntervalSince(self.lastRefresh) >= 15 { self.fetch() }
        }
        fetch()
        if !snapshotMode && !CommandLine.arguments.contains("--headless") && (demo || CommandLine.arguments.contains("--show")) { show() }
    }
    func caps(_ event: NSEvent) {
        guard event.keyCode == 57 else { return }
        if Date().timeIntervalSince(lastCaps) < 0.35 { show(); lastCaps = .distantPast }
        else { lastCaps = Date() }
    }
    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(); return }
        if panel.isVisible { panel.orderOut(nil) } else { show() }
    }
    @objc func spaceChanged() { if autoTile { tile() } }
    func makePanel() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 52), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.isOpaque = false
        panel.backgroundColor = .clear; panel.hasShadow = true; panel.appearance = NSAppearance(named: .darkAqua)
        canvas = Canvas(frame: panel.contentView!.bounds); canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 0.99).cgColor
        canvas.layer?.cornerRadius = 10; canvas.layer?.masksToBounds = true
        panel.contentView = canvas
        _ = button(">", 9, 5, 18, on: canvas) { [weak self] in self?.providerMenu() }
        folderField = NSTextField(frame: NSRect(x: 26, y: 6, width: 201, height: 20))
        folderField.font = .monospacedSystemFont(ofSize: 12, weight: .semibold); folderField.isBordered = false
        folderField.drawsBackground = false; folderField.focusRingType = .none; folderField.delegate = self
        folderField.placeholderString = "project or terminal"; folderField.stringValue = (folder as NSString).lastPathComponent
        folderField.setAccessibilityLabel("Search projects and terminals"); canvas.addSubview(folderField)
        providerButton = button(provider, 227, 5, 58, on: canvas) { [weak self] in self?.providerMenu() }
        countButton = button("···", 291, 5, 46, on: canvas) { [weak self] in
            guard let self = self else { return }
            if self.expanded { self.expanded = false; self.layout() }
            else { self.expand("sessions") }
        }
        countButton.setAccessibilityLabel("Show terminal sessions"); countButton.toolTip = "All terminals · ⌘L"
        countButton.wantsLayer = true; countButton.layer?.cornerRadius = 5; countButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        awakeButton = button("awake", 341, 5, 52, on: canvas) { [weak self] in self?.awakeMenu() }
        awakeButton.setAccessibilityLabel("Keep awake timer")
        composerScroll = NSScrollView(frame: NSRect(x: 25, y: 28, width: width-45, height: 20))
        composerScroll.drawsBackground = false; composerScroll.hasVerticalScroller = false
        composer = NSTextView(frame: composerScroll.bounds)
        composer.isRichText = false; composer.drawsBackground = false; composer.font = .systemFont(ofSize: 13)
        composer.textColor = .labelColor; composer.insertionPointColor = accent; composer.textContainerInset = .zero
        composer.textContainer?.lineFragmentPadding = 0; composer.textContainer?.widthTracksTextView = true
        composer.isVerticallyResizable = true; composer.autoresizingMask = [.width]; composer.delegate = self
        composer.maxSize = NSSize(width: width-45, height: .greatestFiniteMagnitude)
        composer.setAccessibilityLabel("Prompt draft. Return submits; Shift Return adds a line.")
        composerScroll.documentView = composer; canvas.addSubview(composerScroll)
        body = Canvas(frame: .zero); canvas.addSubview(body)
        layout()
    }
    @discardableResult func button(_ title: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, on view: NSView, action: @escaping () -> Void) -> ActionButton {
        let b = ActionButton(title, frame: NSRect(x: x, y: y, width: w, height: 22), action: action)
        b.setAccessibilityLabel(title); view.addSubview(b); return b
    }
    @discardableResult func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat = 18, size: CGFloat = 11, color: NSColor = .secondaryLabelColor, on view: NSView? = nil) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text); l.frame = NSRect(x: x, y: y, width: w, height: h)
        l.font = .systemFont(ofSize: size); l.textColor = color; l.maximumNumberOfLines = Int(h/14)+1
        l.lineBreakMode = .byTruncatingTail; (view ?? body).addSubview(l); return l
    }
    func show(compact: Bool = true) {
        if compact { expanded = false }
        layout(); panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(folder.isEmpty && selectedID == nil ? folderField : composer)
        fetch()
    }
    func expand(_ tab: String) {
        expanded = true; detailsVisible = false; selectedProposal = nil
        mode = tab; query = ""; scrollOffset = 0; keyboardIndex = 0; layout()
    }
    func goBack() {
        if !expanded { panel.orderOut(nil); return }
        if selectedProposal != nil { selectedProposal = nil; mode = "updates" }
        else if detailsVisible { detailsVisible = false }
        else { expanded = false }
        layout()
    }
    func saveDraft() { drafts[draftKey] = composer.string }
    func newSession() {
        saveDraft(); selectedID = nil; selectedProposal = nil; inspection = nil; mode = "new"; query = ""
        composer.string = drafts[draftKey] ?? ""; folderField.stringValue = (folder as NSString).lastPathComponent
        expanded = true; detailsVisible = false; keyboardIndex = 0; layout(); folderField.selectText(nil)
    }
    func showList() {
        saveDraft(); selectedID = nil; selectedProposal = nil; inspection = nil
        mode = "sessions"; query = ""; folderField.stringValue = ""; composer.string = drafts[draftKey] ?? ""
        expanded = true; detailsVisible = false; keyboardIndex = 0; layout()
    }
    func select(_ session: Record) {
        saveDraft(); selectedID = session.text("id"); selectedProposal = nil; inspection = nil; query = ""
        folderField.stringValue = session.text("project"); composer.string = drafts[draftKey] ?? ""
        expanded = true; detailsVisible = true; mode = "sessions"; layout()
    }
    func layout() {
        guard canvas != nil else { return }
        let hh = headerHeight
        composerScroll.frame.size.height = hh-31
        let restoreTextFocus = detailTextScroll?.documentView === panel.firstResponder
        for scroll in body.subviews.compactMap({ $0 as? NSScrollView }) {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
        body.subviews.forEach { $0.removeFromSuperview() }
        body.frame = NSRect(x: 0, y: hh, width: width, height: 0)
        var height: CGFloat = hh
        // A real placeholder, kept separate from the editable text and accessibility value.
        canvas.subviews.filter { $0.identifier?.rawValue == "placeholder" }.forEach { $0.removeFromSuperview() }
        if composer.string.isEmpty {
            let hint = selectedID == nil ? "prompt  ↵" : "draft  ↵ copy & open"
            let l = label(hint, 26, 29, 330, 19, size: 13, color: .tertiaryLabelColor, on: canvas)
            l.identifier = NSUserInterfaceItemIdentifier("placeholder")
            // Put the placeholder behind the editor so clicking always focuses the draft.
            canvas.addSubview(l, positioned: .below, relativeTo: composerScroll)
        }
        providerButton.title = selected?.text("provider") ?? provider
        let counts = state.record("counts"); let attention = Int(counts.number("attention")) + state.records("proposals").filter { $0.text("status") == "pending" }.count
        let warning = !error.isEmpty || !missingAccess.isEmpty || state.flag("stale") || !(state["warnings"] as? [String] ?? []).isEmpty
        let detail = !error.isEmpty ? error : !missingAccess.isEmpty ? "Terminal access needed. Click to connect." : warning ? "Connection needs attention. Click for details." : Date().timeIntervalSince(receiptDate) < 8 ? receipt : "All terminals · ⌘L"
        countButton.title = "\(Int(counts.number("total")))" + (warning ? " !" : attention > 0 ? " · \(attention)" : "")
        countButton.toolTip = detail
        countButton.setAccessibilityLabel("\(Int(counts.number("total"))) terminals, \(attention) updates. " + detail)
        countButton.contentTintColor = warning ? .systemOrange : attention > 0 || Date().timeIntervalSince(receiptDate) < 8 ? accent : .secondaryLabelColor
        statusItem?.button?.title = attention > 0 ? " \(attention)" : ""
        statusItem?.button?.toolTip = "TD · \(Int(counts.number("total"))) terminals · \(attention) updates"
        let awake = state.record("awake").text("state", "off")
        awakeButton.title = awake == "off" ? "awake" : awake; awakeButton.contentTintColor = awake == "off" ? .secondaryLabelColor : accent
        if expanded {
            let line = NSView(frame: NSRect(x: 14, y: 0, width: width-28, height: 1)); line.wantsLayer = true
            line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor; body.addSubview(line)
            let tabs = [("sessions", "Sessions"), ("updates", "Updates"), ("new", "+ New")]
            for (i, tab) in tabs.enumerated() {
                let b = button(tab.1, 12 + CGFloat(i)*91, 8, 84, on: body) { [weak self] in
                    guard let self = self else { return }
                    if tab.0 == "new" { self.newSession() }
                    else { self.showList(); self.mode = tab.0; self.layout() }
                }
                if tab.0 == mode { b.contentTintColor = .labelColor; b.wantsLayer = true; b.layer?.cornerRadius = 5; b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor }
            }
            let refresh = button(pending ? "···" : "↻", 358, 8, 28, on: body) { [weak self] in self?.fetch(force: true) }
            refresh.isEnabled = !pending; refresh.toolTip = "Refresh · ⌘R"
            var start: CGFloat = 42
            if !missingAccess.isEmpty {
                label("Allow TD to see " + missingAccess.map { $0.1 }.joined(separator: " and ") + ".", 18, start, width-36, 20, color: .systemOrange)
                _ = button("Allow terminal access…", 12, start+22, 188, on: body) { [weak self] in self?.requestTerminalAccess() }
                start += 56
            }
            var bottom: CGFloat
            if let proposalID = selectedProposal { bottom = proposalDetail(proposalID, at: start) }
            else if selectedID != nil && detailsVisible { bottom = sessionDetail(at: start) }
            else if mode == "updates" { bottom = updates(at: start) }
            else { bottom = list(at: start) }
            bottom = navigatorFooter(at: bottom + 8)
            let message: String
            if pending { message = "Checking terminals…" }
            else if !error.isEmpty { message = error }
            else if state.flag("stale") { message = "Last view held · refresh to reconnect" }
            else if let warnings = state["warnings"] as? [String], !warnings.isEmpty { message = warnings.joined(separator: " · ") }
            else if Date().timeIntervalSince(receiptDate) < 30 { message = receipt }
            else { message = demo ? "EDWARD DEMO · real terminals untouched" : "Updated \(max(0, Int(Date().timeIntervalSince1970-state.number("updated_at"))))s ago · ⇧↵ new line · esc back" }
            label(message, 17, bottom+5, width-34, 30, size: 10, color: error.isEmpty ? .secondaryLabelColor : .systemOrange)
            height += bottom + 38
            body.frame.size.height = bottom+38
        }
        let screen = statusItem?.button?.window?.screen ?? NSScreen.main!
        let anchor = statusItem?.button?.window?.frame ?? NSRect(x: screen.visibleFrame.maxX-20, y: screen.visibleFrame.maxY, width: 20, height: 0)
        let x = max(screen.visibleFrame.minX+8, min(anchor.maxX-width, screen.visibleFrame.maxX-width-8))
        let y = max(screen.visibleFrame.minY+8, min(anchor.minY-4, screen.visibleFrame.maxY)-height)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        canvas.frame = NSRect(x: 0, y: 0, width: width, height: height)
        if restoreTextFocus, detailTextScroll?.superview === body { panel.makeFirstResponder(detailTextScroll?.documentView) }
    }
    func scroll(_ document: NSView, y: CGFloat, height: CGFloat) {
        let s = NSScrollView(frame: NSRect(x: 0, y: y, width: width, height: height))
        s.drawsBackground = false; s.hasVerticalScroller = true; s.autohidesScrollers = true
        s.documentView = document; body.addSubview(s)
        s.contentView.scroll(to: NSPoint(x: 0, y: min(scrollOffset, max(0, document.frame.height-height))))
        s.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: s.contentView)
    }
    @objc func scrolled(_ notification: Notification) { if let clip = notification.object as? NSClipView { scrollOffset = clip.bounds.minY } }
    func list(at y: CGFloat) -> CGFloat {
        let searching = query.lowercased()
        let document = Canvas(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        var dy: CGFloat = 0
        if mode == "new" {
            let folders = state.records("folders").filter { searching.isEmpty || $0.text("name").lowercased().contains(searching) }
            for (index, f) in folders.enumerated() {
                let b = button(f.text("name"), 16, dy, width-32, on: document) { [weak self] in
                    guard let self = self else { return }; self.saveDraft(); self.folder = f.text("path")
                    self.defaults.set(self.folder, forKey: "workspace.folder"); self.query = ""
                    self.folderField.stringValue = f.text("name"); self.composer.string = self.drafts[self.draftKey] ?? ""
                    self.expanded = false; self.layout(); self.panel.makeFirstResponder(self.composer)
                }
                b.alignment = .left; b.frame.size.height = 32; b.contentTintColor = .labelColor; dy += 34
                if index == keyboardIndex && !query.isEmpty { b.wantsLayer = true; b.layer?.cornerRadius = 6; b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor }
            }
            if folders.isEmpty {
                label(state.text("folders_error", "No matching folder in Desktop/Code."), 18, 10, width-36, 45, on: document); dy = 70
            }
        } else {
            let filtered = sessions.filter { s in searching.isEmpty || ["project", "provider", "cwd", "tty", "name"].contains { s.text($0).lowercased().contains(searching) } }
            for (index, s) in filtered.enumerated() { document.addSubview(SessionRow(s, y: dy, width: width, selected: s.flag("pinned") || (!query.isEmpty && index == keyboardIndex)) { [weak self] in self?.select(s) }); dy += 52 }
            if filtered.isEmpty {
                label(sessions.isEmpty ? "Your next terminal will appear here." : "No matches. Your other terminals are still held.", 18, 12, width-36, 42, on: document); dy = 72
            }
        }
        document.frame.size.height = dy; let h = min(312, max(64, dy)); scroll(document, y: y, height: h)
        return y+h
    }
    func sessionDetail(at y: CGFloat) -> CGFloat {
        _ = button("‹ All terminals", 12, y, 105, on: body) { [weak self] in self?.showList() }
        guard let s = selected else {
            label("This terminal closed. Your draft is held.", 18, y+36, width-36, 40); return y+86
        }
        label(s.text("provider") + " · " + s.text("tty").replacingOccurrences(of: "/dev/", with: ""), 165, y+3, 215, size: 10)
        label(s.text("project"), 18, y+32, width-36, 24, size: 16, color: .labelColor)
        label(statusName(s), 18, y+60, width-36, 19, color: statusColor(s))
        label(s.text("summary"), 18, y+86, width-36, 56, size: 12, color: .labelColor)
        let age = s.number("report_at") > 0 ? "\(max(0, Int((Date().timeIntervalSince1970-s.number("report_at"))/60)))m ago · " + s.text("report_by") : "Observed process · awaiting an agent report"
        label(age, 18, y+145, width-36, 16, size: 10)
        var dy = y+166
        for (i, item) in [("Open", "focus"), ("Inspect", "read"), (s.flag("pinned") ? "Release" : "Hold focus", "pin"), ("Seen", "acknowledge"), ("Later", "snooze")].enumerated() {
            let b = button(item.0, 12+CGFloat(i)*76, dy, 74, on: body) { [weak self] in self?.act(item.1, ["session": s.text("id")]) }
            b.isEnabled = !pending && (!(item.1 == "read" || item.1 == "focus") || (!s.flag("stale") && s.flag("can_"+item.1)))
            if i == 0 { b.contentTintColor = accent }
        }
        dy += 33
        if !s.text("evidence").isEmpty && inspection == nil {
            label("Evidence · " + s.text("evidence"), 18, dy, width-36, 42, size: 10); dy += 46
        }
        if let output = inspection {
            _ = button("Close inspection", 12, dy, 120, on: body) { [weak self] in self?.inspection = nil; self?.layout() }
            label("Terminal text · untrusted", 203, dy+4, 180, 18, size: 10); dy += 27
            textBox(output, y: dy, height: 150); dy += 158
        }
        if s.text("provider") != "shell" {
            let c = state.record("controller"); let enabled = c.flag("enabled") && c.text("session") == s.text("id")
            let b = button(enabled ? "●  Navigation on" : "○  Let this agent navigate", 12, dy, 220, on: body) { [weak self] in
                self?.act("controller", ["session": s.text("id"), "enabled": !enabled])
            }
            b.contentTintColor = enabled ? accent : .labelColor; b.isEnabled = enabled || (!pending && !s.flag("stale"))
            b.setAccessibilityLabel(enabled ? "Turn navigation off" : "Let this agent navigate")
            if enabled {
                let copy = button("Copy handoff", 264, dy, 118, on: body) { [weak self] in self?.act("guide") }; copy.contentTintColor = accent; copy.isEnabled = !pending
            }
            dy += 26
            label(enabled ? "Reads, focuses, reports. You review proposed prompts." : "Choose one navigator. Pause it here whenever you need.", 18, dy, width-36, 28, size: 10); dy += 29
        }
        return dy
    }
    func updates(at y: CGFloat) -> CGFloat {
        let doc = Canvas(frame: NSRect(x: 0, y: 0, width: width, height: 0)); var dy: CGFloat = 0
        if demo {
            let b = button("Try Edward's check-in →", 14, dy, width-28, on: doc) { [weak self] in self?.act("demo") }
            b.alignment = .left; b.contentTintColor = accent; b.isEnabled = !pending; dy += 32
        }
        for p in state.records("proposals").filter({ $0.text("status") == "pending" }) {
            let target = sessions.first { $0.text("id") == p.text("session") }
            let b = button("Review → " + (target?.text("project") ?? "Disconnected terminal"), 14, dy, width-28, on: doc) { [weak self] in self?.selectedProposal = p.text("id"); self?.scrollOffset = 0; self?.layout() }
            b.alignment = .left; b.contentTintColor = accent
            label(p.text("reason"), 18, dy+25, width-36, 34, size: 11, on: doc); dy += 67
        }
        for s in sessions.filter({ $0.flag("needs_attention") }) { doc.addSubview(SessionRow(s, y: dy, width: width, selected: false) { [weak self] in self?.select(s) }); dy += 52 }
        let events = state.records("events").prefix(15)
        if !events.isEmpty { label("RECENT RECEIPTS", 18, dy+10, width-36, 18, size: 9, on: doc); dy += 35 }
        for e in events {
            label(e.text("message"), 18, dy, width-36, 34, size: 11, color: .labelColor, on: doc)
            let ago = max(0, Int((Date().timeIntervalSince1970-e.number("time"))/60))
            label("\(ago)m · " + e.text("actor"), 18, dy+35, width-36, 17, size: 9, on: doc); dy += 59
        }
        if dy == 0 { label("All caught up. New updates will arrive here.", 18, 12, width-36, 40, on: doc); dy = 74 }
        doc.frame.size.height = dy; let h = min(312, dy); scroll(doc, y: y, height: h); return y+h
    }
    func proposalDetail(_ id: String, at y: CGFloat) -> CGFloat {
        _ = button("‹ Updates", 12, y, 88, on: body) { [weak self] in self?.selectedProposal = nil; self?.layout() }
        guard let p = state.records("proposals").first(where: { $0.text("id") == id }) else { return y+40 }
        let s = sessions.first { $0.text("id") == p.text("session") }
        label("To " + (s?.text("project") ?? "Disconnected terminal"), 18, y+34, width-36, 24, size: 15, color: .labelColor)
        label((s?.text("provider") ?? "") + " · " + (s?.text("tty") ?? p.text("session")), 18, y+62, width-36, 18, size: 10)
        label(p.text("reason"), 18, y+88, width-36, 44, color: .labelColor)
        textBox(p.text("prompt"), y: y+135, height: 140)
        let ready = s?.flag("ready_to_send") == true && p.text("status") == "pending"
        let approve = button(p.text("status") == "pending" ? "Approve & send" : p.text("status").capitalized, 14, y+285, 134, on: body) { [weak self] in self?.act("approve", ["proposal": id]) }
        approve.isEnabled = !pending && ready; approve.contentTintColor = accent
        let copy = button("Copy prompt", 155, y+285, 110, on: body) { [weak self] in self?.copy(p.text("prompt"), receipt: "Prompt copied. Paste it into the intended terminal.") }
        copy.isEnabled = !pending
        let dismiss = button("Dismiss", 283, y+285, 94, on: body) { [weak self] in self?.act("dismiss", ["proposal": id]) }
        dismiss.isEnabled = !pending && p.text("status") == "pending"
        let deliveryHint = p.text("status") == "delivered" ? "Prompt delivered. Awaiting the agent's own result." : p.text("status") == "uncertain" ? "Delivery uncertain. Inspect the terminal before continuing." : ready ? "One delivery. The agent reports the result separately." : "Needs a fresh waiting report. Copy the prompt to continue."
        label(deliveryHint, 18, y+316, width-36, 30, size: 10)
        return y+349
    }
    func textBox(_ text: String, y: CGFloat, height: CGFloat) {
        if let scroll = detailTextScroll, let tv = scroll.documentView as? NSTextView, tv.string == text {
            scroll.frame = NSRect(x: 16, y: y, width: width-32, height: height)
            body.addSubview(scroll); return
        }
        let scroll = NSScrollView(frame: NSRect(x: 16, y: y, width: width-32, height: height))
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width-32, height: height))
        tv.isEditable = false; tv.isSelectable = true; tv.isRichText = false; tv.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        tv.textColor = .labelColor; tv.backgroundColor = NSColor.white.withAlphaComponent(0.03); tv.string = text
        tv.textContainerInset = NSSize(width: 6, height: 6); tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true; tv.autoresizingMask = [.width]; scroll.documentView = tv; body.addSubview(scroll)
        detailTextScroll = scroll
    }
    func navigatorFooter(at y: CGFloat) -> CGFloat {
        let line = NSView(frame: NSRect(x: 14, y: y, width: width-28, height: 1)); line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor; body.addSubview(line)
        let c = state.record("controller")
        let names = ["off":"No navigator", "ready":"Awaiting check-in", "active":"Checked in", "quiet":"Quiet · last check-in over 90s", "disconnected":"Disconnected · navigation paused"]
        let text = c.flag("enabled") ? c.text("name") + " · " + (names[c.text("state")] ?? "") : "Choose a terminal to give an agent the map"
        label(text, 18, y+12, width-96, 29, size: 10, color: c.text("state") == "active" ? accent : .secondaryLabelColor)
        if c.flag("enabled") {
            let stop = button("Pause", width-76, y+7, 60, on: body) { [weak self] in self?.act("controller", ["enabled": false]) }
            stop.isEnabled = true; stop.toolTip = "Revoke the handoff and cancel pending proposals"
        }
        return y+39
    }
    func controlTextDidChange(_ notification: Notification) {
        saveDraft(); let hadSelection = selectedID != nil
        selectedID = nil; selectedProposal = nil; inspection = nil; detailsVisible = false
        if hadSelection { composer.string = drafts[draftKey] ?? "" }
        query = folderField.stringValue; expanded = true; scrollOffset = 0; keyboardIndex = 0
        if mode == "updates" { mode = "sessions" }; layout()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let choices = mode == "new" ? state.records("folders").filter { query.isEmpty || $0.text("name").localizedCaseInsensitiveContains(query) } : sessions.filter { s in query.isEmpty || ["project", "provider", "tty", "cwd", "name"].contains { s.text($0).localizedCaseInsensitiveContains(query) } }
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveUp(_:)) {
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            keyboardIndex = max(0, min(choices.count-1, keyboardIndex+delta)); expanded = true
            let rowHeight: CGFloat = mode == "new" ? 34 : 52
            scrollOffset = max(0, CGFloat(keyboardIndex)*rowHeight-156); layout(); return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            guard !choices.isEmpty else { return true }
            let choice = choices[min(keyboardIndex, choices.count-1)]
            if mode == "new" {
                saveDraft(); folder = choice.text("path"); defaults.set(folder, forKey: "workspace.folder")
                folderField.stringValue = choice.text("name"); composer.string = drafts[draftKey] ?? ""
                expanded = false; query = ""; layout(); panel.makeFirstResponder(composer)
            } else {
                // The Enter shortcut follows the same visible ordering as the list.
                select(choice); panel.makeFirstResponder(composer)
            }
            return true
        }
        return false
    }
    func textDidChange(_ notification: Notification) {
        saveDraft(); layout(); composer.scrollRangeToVisible(composer.selectedRange())
    }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { textView.insertNewlineIgnoringFieldEditor(nil); return true }
            submit(); return true
        }
        return false
    }
    func submit() {
        guard !pending else { return }
        let prompt = composer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sid = selectedID {
            if !prompt.isEmpty { copy(prompt, receipt: "Draft copied. Paste it in the terminal when ready.") }
            act("focus", ["session": sid]); return
        }
        guard query.isEmpty, !folder.isEmpty, folderField.stringValue == (folder as NSString).lastPathComponent else {
            expanded = true
            if query.isEmpty { mode = "new" }
            layout(); folderField.selectText(nil); return
        }
        act("launch", ["folder": folder, "provider": provider, "prompt": prompt])
    }
    func copy(_ text: String, receipt message: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        receipt = message; receiptDate = Date(); layout()
    }
    func fetch(force: Bool = false) {
        guard !pending else { return }
        if !demo {
            let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
            missingAccess = [("com.googlecode.iterm2", "iTerm2"), ("com.apple.Terminal", "Terminal")].filter {
                guard running.contains($0.0) else { return false }
                guard let target = NSAppleEventDescriptor(descriptorType: typeApplicationBundleID, data: Data($0.0.utf8)) else { return true }
                let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
                return status == -1743 || status == -1744
            }
        }
        act(missingAccess.isEmpty ? (force ? "refresh" : "state") : "cached")
    }
    func requestTerminalAccess() {
        let targets = missingAccess
        DispatchQueue.global(qos: .userInitiated).async {
            var denied = false
            for (bundle, _) in targets {
                guard let target = NSAppleEventDescriptor(descriptorType: typeApplicationBundleID, data: Data(bundle.utf8)) else { continue }
                if AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true) == -1743 { denied = true }
            }
            DispatchQueue.main.async {
                if denied { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!) }
                self.fetch(force: true)
            }
        }
    }
    func act(_ action: String, _ fields: Record = [:]) {
        let pause = action == "controller" && fields["enabled"] as? Bool == false
        guard !pending || pause else { return }; pending = true; error = ""
        let requestID = UUID(); activeRequest = requestID
        var request = fields; request["action"] = action
        let sourceDraft = draftKey; let sentDraft = composer?.string ?? ""
        layout()
        run(["workspace"] + (demo ? ["--demo"] : []), input: request, urgent: pause) { [weak self] response in
            guard let self = self, self.activeRequest == requestID else { return }; self.pending = false; self.lastRefresh = Date()
            if let problem = response["error"] as? String { self.error = problem }
            else {
                self.state = response.record("state")
                if !self.missingAccess.isEmpty {
                    self.state["stale"] = true
                    self.state["sessions"] = self.sessions.map { session -> Record in var s = session; s["stale"] = true; s["ready_to_send"] = false; return s }
                }
                let result = response.record("result")
                if !result.text("message").isEmpty { self.receipt = result.text("message"); self.receiptDate = Date() }
                if action == "read" && self.selectedID == fields.text("session") { self.inspection = result.text("text") }
                if action == "guide" { self.copy(result.text("text"), receipt: "Handoff copied. Paste it into the selected agent.") }
                if action == "launch" && !self.demo {
                    self.finishLaunch(draft: sourceDraft, submitted: sentDraft)
                    if self.expanded { self.mode = "sessions" }
                }
                if action == "focus" && self.draftKey == sourceDraft && self.composer.string == sentDraft { self.panel.orderOut(nil) }
            }
            self.layout()
            self.didRespond?(action)
            if self.snapshotMode { self.captureIfRequested() }
        }
    }
    func finishLaunch(draft key: String, submitted: String) {
        // Only consume the exact submitted revision; a newer draft may already be parked elsewhere.
        if drafts[key] == submitted { drafts[key] = "" }
        if draftKey == key && composer.string == submitted { composer.string = "" }
    }
    func run(_ arguments: [String], input: Record? = nil, urgent: Bool = false, completion: @escaping (Record) -> Void) {
        let executable = tdPath
        (urgent ? DispatchQueue.global(qos: .userInitiated) : queue).async {
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = NSHomeDirectory()+"/bin:"+NSHomeDirectory()+"/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = env
            let output = Pipe(); let stdin = Pipe(); process.standardOutput = output; process.standardError = output; process.standardInput = stdin
            do {
                try process.run()
                if let input = input { try stdin.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: input)) }
                try stdin.fileHandleForWriting.close()
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now()+40, execute: timeout)
                let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); timeout.cancel()
                let decoded = (try? JSONSerialization.jsonObject(with: data)) as? Record
                let response = decoded ?? (input == nil ? [process.terminationStatus == 0 ? "message" : "error": String(data: data, encoding: .utf8) ?? "Command finished."] : ["error": process.terminationStatus == 0 ? "Unexpected workspace response." : "The workspace did not respond. Your draft is held; refresh to reconnect."])
                DispatchQueue.main.async { completion(response) }
            } catch { DispatchQueue.main.async { completion(["error": "Could not start the workspace: " + error.localizedDescription]) } }
        }
    }
    func providerMenu() {
        let menu = NSMenu()
        for name in ["claude", "claudex", "codex", "hermes"] {
            let item = NSMenuItem(title: name.capitalized, action: #selector(pickProvider(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = name; item.state = provider == name ? .on : .off; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: providerButton.frame.minX, y: 28), in: canvas)
    }
    @objc func pickProvider(_ item: NSMenuItem) {
        provider = item.representedObject as? String ?? "codex"; defaults.set(provider, forKey: "workspace.provider")
        if selectedID != nil { newSession() }; layout()
    }
    func awakeMenu() {
        let menu = NSMenu()
        for (title, duration) in [("Off", "off"), ("1 hour", "1h"), ("4 hours", "4h"), ("24 hours", "24h")] {
            let i = NSMenuItem(title: title, action: #selector(pickAwake(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = duration; i.state = state.record("awake").text("state", "off") == duration ? .on : .off; menu.addItem(i)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 325, y: 28), in: canvas)
    }
    @objc func pickAwake(_ item: NSMenuItem) { act("awake", ["duration": item.representedObject as? String ?? "off"]) }
    func showMenu() {
        let m = NSMenu()
        for (title, action) in [("Quick Add", #selector(menuQuick)), ("All terminals", #selector(menuSessions)), ("Tile windows", #selector(menuTile)), ("Auto-tile on Space change", #selector(menuAutoTile)), ("Quit TD", #selector(menuQuit))] {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: ""); i.target = self
            if action == #selector(menuAutoTile) { i.state = autoTile ? .on : .off }; m.addItem(i)
        }
        statusItem.menu = m; statusItem.button?.performClick(nil); statusItem.menu = nil
    }
    @objc func menuQuick() { newSession(); show() }
    @objc func menuSessions() { showList(); show(compact: false) }
    @objc func menuTile() { tile() }
    @objc func menuAutoTile() { autoTile.toggle() }
    @objc func menuQuit() { NSApp.terminate(nil) }
    func tile() {
        if demo { receipt = "Demo: real windows stay in place."; receiptDate = Date(); layout(); return }
        run(["tile"]) { [weak self] response in
            self?.error = response.text("error"); self?.receipt = response.text("error").isEmpty ? "Windows tiled." : ""
            self?.receiptDate = Date(); self?.layout()
        }
    }
    var captured = false
    func captureIfRequested() {
        guard !captured, let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index+1 else { return }
        captured = true
        let path = CommandLine.arguments[index+1]
        let scene = ProcessInfo.processInfo.environment["TD_SNAPSHOT_SCENE"] ?? "sessions"
        if scene == "detail", let s = sessions.first(where: { $0.text("project").lowercased().contains("edward") && $0.text("provider") != "shell" }) { select(s) }
        else if scene == "compact" { expanded = false; folderField.stringValue = "Peppe_agent" }
        else if scene == "updates" { mode = "updates"; expanded = true }
        else { mode = "sessions"; expanded = true }
        query = ""; layout()
        DispatchQueue.main.asyncAfter(deadline: .now()+0.3) {
            guard let bitmap = self.canvas.bitmapImageRepForCachingDisplay(in: self.canvas.bounds) else { exit(2) }
            self.canvas.cacheDisplay(in: self.canvas.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(3) }
            do {
                try data.write(to: URL(fileURLWithPath: path))
                print("Native snapshot: \(path) · \(Int(self.width))×\(Int(self.canvas.frame.height)) · \(self.sessions.count) sessions")
                print("Fresh: \(!self.state.flag("stale")) · warnings: \(self.state["warnings"] ?? []) · error: \(self.error)")
                exit(self.state.flag("stale") || !self.error.isEmpty ? 5 : 0)
            }
            catch { print(error); exit(4) }
        }
    }
}
if CommandLine.arguments.contains("--version") {
    print("TD native workspace 2.0")
    exit(0)
}
let application = NSApplication.shared
let delegate = TD()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
