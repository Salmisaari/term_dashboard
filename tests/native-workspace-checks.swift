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
        stage = 8; delegate.act("focus", ["session": "disconnected-id"])
    case 8:
        check(!delegate.error.isEmpty, "Disconnected target has actionable feedback")
        check(delegate.composer.string == heldDraft, "Draft survives a transport action failure")
        delegate.error = ""; delegate.expanded = false; delegate.composer.string = ""
        delegate.selectedID = nil; delegate.folderField.stringValue = "Peppe_agent"; delegate.receiptDate = .distantPast
        delegate.layout(); check(delegate.panel.frame.height == 52, "Resting bar stays 400 × 52 points")
        screenshot("td-native-compact")
        restoreClipboard(); print("Native AppKit Edward workflow passed."); exit(0)
    default: break
    }
}
DispatchQueue.main.asyncAfter(deadline: .now()+55) { print("FAIL: native workflow timed out at stage \(stage)"); restoreClipboard(); exit(2) }
application.run()
