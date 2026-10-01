// AppKit interaction checks, appended to the real native source by test-menubar.sh.
let application = NSApplication.shared
let delegate = TD()
application.delegate = delegate
application.setActivationPolicy(.accessory)
let savedClipboard = NSPasteboard.general.pasteboardItems?.map { item in
    Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
} ?? []
func restoreClipboard() {
    NSPasteboard.general.clearContents()
    let items = savedClipboard.map { values -> NSPasteboardItem in
        let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item
    }
    NSPasteboard.general.writeObjects(items)
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { print("FAIL: " + message); restoreClipboard(); exit(1) }
    print("PASS: " + message)
}
func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
func click(_ title: String) {
    let match = descendants(delegate.canvas).compactMap { $0 as? ActionButton }.first { $0.title.contains(title) }
    check(match != nil && match!.isEnabled, "Control available: " + title)
    match!.performClick(nil)
}
func screenshot(_ name: String) {
    let path = ProcessInfo.processInfo.environment["TD_NATIVE_ARTIFACTS"] ?? "/tmp"
    delegate.layout()
    let bitmap = delegate.canvas.bitmapImageRepForCachingDisplay(in: delegate.canvas.bounds)!
    delegate.canvas.cacheDisplay(in: delegate.canvas.bounds, to: bitmap)
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path+"/"+name+".png"))
}
var stage = 0
var proposalID = ""
let heldDraft = "First thought\nSecond thought"
delegate.didRespond = { action in
    switch stage {
    case 0:
        delegate.timer?.invalidate()
        check(delegate.sessions.count == 6, "Native inventory loaded without HTTP")
        let savedAwake = delegate.state["awake"]
        delegate.state["awake"] = ["state": "4h", "closed_lid": true, "message": "Closed-lid awake · stops at 10% battery."]
        delegate.layout()
        check(delegate.awakeButton.title == "4h" && delegate.awakeButton.toolTip?.contains("Closed-lid awake") == true, "Awake control explains closed-lid protection")
        delegate.state["awake"] = ["state": "off", "error": "Cannot verify closed-lid protection."]
        delegate.layout()
        check(delegate.awakeButton.toolTip == "Cannot verify closed-lid protection." && delegate.awakeButton.contentTintColor == .systemOrange, "Awake failure remains visible when timer is off")
        delegate.state["awake"] = savedAwake
        delegate.panel.orderOut(nil)
        delegate.pending = true // Exercise presentation without starting another discovery request.
        delegate.statusItem.button!.performClick(nil)
        check(delegate.panel.isVisible, "One click on the menu-bar icon opens the panel")
        check(delegate.panel.isKeyWindow, "The opened panel accepts keyboard input")
        check(delegate.panel.frame.height == 52, "Main view opens as the compact two-line bar")
        delegate.countButton.performClick(nil)
        check(delegate.expanded && delegate.panel.frame.height > 52, "Session button explicitly expands the workspace")
        delegate.statusItem.button!.performClick(nil)
        delegate.statusItem.button!.performClick(nil)
        check(!delegate.expanded && delegate.panel.frame.height == 52, "Reopening tucks the previous workspace view away")
        delegate.panel.orderOut(nil)
        delegate.pending = false
        delegate.composer.string = String(repeating: "A longer thought that wraps naturally. ", count: 20)
        delegate.composer.setSelectedRange(NSRange(location: (delegate.composer.string as NSString).length, length: 0))
        delegate.textDidChange(Notification(name: NSText.didChangeNotification))
        check(delegate.headerHeight > 52 && delegate.headerHeight <= 120, "Wrapped prompts grow within the compact five-line limit")
        check(delegate.composerScroll.contentView.bounds.minY > 0, "Long drafts keep the current typing position visible")
        delegate.composer.string = ""; delegate.textDidChange(Notification(name: NSText.didChangeNotification))
        let previousFolder = delegate.folder
        delegate.folder = "/example/old-project"; delegate.folderField.stringValue = "different project"
        delegate.query = "different project"; delegate.composer.string = "A thought for the new project"
        delegate.submit()
        check(!delegate.pending && delegate.expanded, "An unfinished project choice cannot launch in the previous folder")
        check(delegate.composer.string == "A thought for the new project", "Choosing the destination preserves the prompt")
        delegate.folder = previousFolder; delegate.query = ""; delegate.composer.string = ""
        delegate.drafts["new:/example/old-project"] = "A newer parked draft"
        delegate.finishLaunch(draft: "new:/example/old-project", submitted: "The earlier submitted draft")
        check(delegate.drafts["new:/example/old-project"] == "A newer parked draft", "Late launch receipts preserve a newer parked draft")
        delegate.expand("sessions"); delegate.folderField.stringValue = "edward"
        delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        check(descendants(delegate.body).compactMap { $0 as? SessionRow }.count == 2, "Search keeps duplicate Edward terminals distinct")
        _ = delegate.control(delegate.folderField, textView: delegate.composer, doCommandBy: #selector(NSResponder.moveDown(_:)))
        _ = delegate.control(delegate.folderField, textView: delegate.composer, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        check(delegate.selectedID == "demo:6", "Arrow + Enter selects the exact second Edward terminal")
        delegate.composer.string = heldDraft; delegate.textDidChange(Notification(name: NSText.didChangeNotification))
        check(delegate.headerHeight == 69, "Multiline draft expands compact bar")
        delegate.select(delegate.sessions.first { $0.text("id") == "demo:1" }!)
        check(delegate.composer.string.isEmpty, "Draft does not leak to another terminal")
        delegate.select(delegate.sessions.first { $0.text("id") == "demo:6" }!)
        check(delegate.composer.string == heldDraft, "Interrupted terminal draft is retained")
        delegate.goBack()
        check(delegate.selectedID == "demo:6" && delegate.composer.string == heldDraft, "Back from details preserves the terminal and draft")
        delegate.goBack()
        check(!delegate.expanded, "Back from the list returns to the minimal bar")
        delegate.countButton.performClick(nil)
        check(descendants(delegate.body).compactMap { $0 as? SessionRow }.count == 6, "Session count opens the inventory even with a selected terminal")
        check(delegate.selectedID == "demo:6" && delegate.composer.string == heldDraft, "Opening inventory keeps the draft destination intact")
        delegate.goBack(); delegate.goBack()
        check(!delegate.expanded && !delegate.panel.isVisible, "Escape from the compact bar closes it without expanding")
        delegate.select(delegate.sessions.first { $0.text("id") == "demo:1" }!)
        stage = 1; click("Let this agent navigate")
    case 1:
        check(delegate.state.record("controller").text("state") == "ready", "Toggle awaits check-in, never fabricates activity")
        stage = 2; click("Copy handoff")
    case 2:
        check(NSPasteboard.general.string(forType: .string)?.contains("TD_AGENT_TOKEN") == true, "Copy handoff uses the native clipboard")
        delegate.showList(); delegate.mode = "updates"; delegate.layout()
        stage = 3; click("Try Edward's check-in")
    case 3:
        check(delegate.state.record("controller").text("state") == "active", "Edward checked in via shared transport")
        check(delegate.state.records("proposals").filter { $0.text("status") == "pending" }.count == 1, "One proposal is held for review")
        proposalID = delegate.state.records("proposals")[0].text("id")
        click("Review →")
        screenshot("td-native-review")
        stage = 4; click("Approve & send")
    case 4:
        check(delegate.state.records("proposals").first { $0.text("id") == proposalID }?.text("status") == "delivered", "Reviewed prompt has a submission receipt")
        delegate.select(delegate.sessions.first { $0.text("id") == "demo:3" }!)
        stage = 5; click("Inspect")
    case 5:
        check(delegate.inspection?.isEmpty == false, "Native inspection shows bounded terminal text")
        let textView = delegate.detailTextScroll!.documentView as! NSTextView
        let range = NSRange(location: 0, length: min(5, (textView.string as NSString).length))
        textView.setSelectedRange(range); delegate.layout()
        check(delegate.detailTextScroll!.documentView === textView && textView.selectedRange() == range, "Refresh preserves text selected for copying")
        stage = 6; click("Hold focus")
    case 6:
        check(delegate.selected?.flag("pinned") == true, "One chosen focus is persisted")
        delegate.inspection = nil; delegate.layout(); screenshot("td-native-detail-active")
        delegate.showList(); screenshot("td-native-sessions")
        delegate.pending = true; delegate.layout() // Pause must remain available during discovery.
        stage = 7; click("Pause")
    case 7:
        check(delegate.state.record("controller").text("state") == "off", "Pause revokes navigation even while another request is pending")
        delegate.select(delegate.sessions.first { $0.text("id") == "demo:6" }!)
        delegate.expanded = false
        stage = 8; delegate.act("focus", ["session": "disconnected-id"])
    case 8:
        check(!delegate.error.isEmpty, "Disconnected target has actionable feedback")
        check(delegate.composer.string == heldDraft, "Draft survives a transport action failure")
        check(!delegate.expanded && delegate.panel.frame.height == delegate.headerHeight, "Action failure leaves the main view compact")
        check(delegate.countButton.title.contains("!"), "Compact failure has a visible status indicator")
        delegate.error = ""; delegate.receipt = "Focus held."; delegate.receiptDate = Date(); delegate.layout()
        check(delegate.panel.frame.height == delegate.headerHeight, "Receipts do not add another row to the main view")
        delegate.missingAccess = [("com.googlecode.iterm2", "iTerm2")]
        stage = 9; delegate.fetch()
    case 9:
        check(!delegate.expanded && delegate.panel.frame.height == delegate.headerHeight, "Permission checks never expand the main view")
        check(delegate.countButton.title.contains("!"), "Missing permission remains discoverable from the compact bar")
        delegate.countButton.performClick(nil)
        check(descendants(delegate.body).compactMap { $0 as? ActionButton }.contains { $0.title == "Allow terminal access…" }, "Explicit expansion reveals the permission control")
        delegate.missingAccess = []; delegate.state["stale"] = false
        delegate.error = ""; delegate.expanded = false; delegate.composer.string = ""
        delegate.selectedID = nil; delegate.folderField.stringValue = "Peppe_agent"; delegate.receiptDate = .distantPast
        delegate.layout(); check(delegate.panel.frame.height == 52, "Resting bar stays 400 × 52 points")
        check(delegate.launchProviders == ["claude", "claudex", "codex", "hermes", "grok"], "Launch cycle includes Grok")
        delegate.provider = "claude"; delegate.layout()
        delegate.providerButton.performClick(nil)
        check(delegate.provider == "claudex" && delegate.providerButton.title == "claudex", "Clicking Claude advances to Claudex")
        delegate.providerButton.performClick(nil)
        check(delegate.provider == "codex", "Clicking Claudex advances to Codex")
        delegate.providerButton.performClick(nil)
        check(delegate.provider == "hermes", "Clicking Codex advances to Hermes")
        delegate.providerButton.performClick(nil)
        check(delegate.provider == "grok" && delegate.providerButton.title == "grok", "Clicking Hermes advances to Grok")
        delegate.providerButton.performClick(nil)
        check(delegate.provider == "claude" && delegate.providerButton.title == "claude", "Clicking Grok wraps back to Claude")
        check(delegate.pickerButton.title == ">", "Picker starts as >")
        delegate.provider = "grok"
        delegate.folderField.stringValue = "penny_agent"
        delegate.pickerButton.performClick(nil)
        check(delegate.swapMode && delegate.pickerButton.title == "⇄", "Clicking > becomes the swap icon")
        check(delegate.provider == "grok", "Swap keeps the agent that was already selected")
        check(delegate.providerButton.title == "grok", "Swap shows the preselected destination")
        delegate.goBack()
        check(!delegate.swapMode && delegate.pickerButton.title == ">", "Escape disarms swap without closing the compact bar")
        check(!delegate.expanded && delegate.panel.frame.height == 52, "Disarming swap leaves the compact bar compact")
        delegate.selectedID = nil
        var extra = delegate.sessions.first { $0.text("id") == "demo:3" }!
        extra["id"] = "demo:9"; extra["provider"] = "codex"; extra["tty"] = "/dev/demo009"
        extra["status"] = "running"; extra["needs_attention"] = false; extra["instance"] = "demo-process-9"
        extra["window_name"] = "receipts"
        var list = delegate.sessions
        if var original = list.first(where: { $0.text("id") == "demo:3" }) {
            original["window_name"] = "inbox"
            if let idx = list.firstIndex(where: { $0.text("id") == "demo:3" }) { list[idx] = original }
        }
        list.append(extra); delegate.state["sessions"] = list
        delegate.folderField.stringValue = "penny_agent"
        delegate.pickerButton.performClick(nil)
        check(delegate.swapMode && delegate.expanded, "Several terminals open the swap picker")
        check(descendants(delegate.body).compactMap { $0 as? SessionRow }.count == 2, "Swap picker lists both terminals")
        check(delegate.selectedID == "demo:3", "An existing waiting terminal is preselected")
        let other = descendants(delegate.body).compactMap { $0 as? SessionRow }.first { $0.session.text("id") == "demo:9" }
        check(other != nil, "The other terminal is in the picker")
        check(other?.accessibilityLabel()?.contains("receipts") == true, "Swap rows show the window title")
        other!.performClick(nil)
        check(delegate.selectedID == "demo:9", "Clicking a row chooses that terminal")
        check(delegate.provider == "grok", "Choosing a terminal does not change the destination agent")
        delegate.countButton.performClick(nil)
        check(!delegate.swapMode && delegate.expanded && delegate.mode == "sessions", "Session count exits the project swap picker into all terminals")
        let allRows = descendants(delegate.body).compactMap { $0 as? SessionRow }
        check(allRows.count == delegate.sessions.count, "All projects are visible after leaving the swap picker")
        let hermes = allRows.first { $0.session.text("provider") == "hermes" }
        check(hermes != nil, "The Hermes session in another project is available")
        hermes!.performClick(nil)
        let hermesID = delegate.selectedID
        delegate.pickerButton.performClick(nil)
        check(delegate.swapMode && delegate.sourceSession()?.text("id") == hermesID && delegate.error.isEmpty, "Selecting Hermes from all terminals arms the exact Hermes source")
        check(delegate.provider == "grok", "Switching source projects retains the destination agent")
        delegate.expand("sessions")
        check(!delegate.swapMode && descendants(delegate.body).compactMap { $0 as? SessionRow }.count == delegate.sessions.count, "The sessions keyboard shortcut also exits swap mode")
        delegate.pickerButton.performClick(nil)
        delegate.newSession()
        check(!delegate.swapMode && delegate.mode == "new" && delegate.selectedID == nil, "New terminal navigation clears the previous swap")
        delegate.folderField.stringValue = "penny_agent"
        delegate.pickerButton.performClick(nil)
        delegate.goBack()
        check(!delegate.swapMode && !delegate.expanded, "Escape closes the picker")
        screenshot("td-native-compact")
        restoreClipboard(); print("Native AppKit Edward workflow passed."); exit(0)
    default: break
    }
}
DispatchQueue.main.asyncAfter(deadline: .now()+55) { print("FAIL: native workflow timed out at stage \(stage)"); restoreClipboard(); exit(2) }
application.run()
