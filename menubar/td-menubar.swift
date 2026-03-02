import Cocoa

class TD: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!

    var autoTile = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "td")
            button.image?.size = NSSize(width: 16, height: 16)
            button.action = #selector(clicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Auto-tile when switching Spaces
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    @objc func spaceChanged() {
        guard autoTile else { return }
        // Short delay to let macOS finish the Space transition
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.run("tile")
            self.flash()
        }
    }

    @objc func clicked() {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showMenu()
        } else {
            // Left click = tile immediately
            run("tile")
            flash()
        }
    }

    func showMenu() {
        let menu = NSMenu()
        menu.minimumWidth = 160

        item(menu, "Tile + Browser",  "t", #selector(tile))
        item(menu, "Tile Grid",       "g", #selector(tileGrid))
        menu.addItem(NSMenuItem.separator())
        item(menu, "Label Tabs",      "l", #selector(label))
        item(menu, "Standup",         "s", #selector(standup))
        menu.addItem(NSMenuItem.separator())
        let autoItem = NSMenuItem(title: "Auto-tile on Space Switch", action: #selector(toggleAuto), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = autoTile ? .on : .off
        menu.addItem(autoItem)
        menu.addItem(NSMenuItem.separator())
        item(menu, "Quit",            "q", #selector(quit))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // restore left-click behavior
    }

    func item(_ menu: NSMenu, _ title: String, _ key: String, _ action: Selector) {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        menu.addItem(mi)
    }

    @objc func tile()     { run("tile"); flash() }
    @objc func tileGrid() { run("tile --no-main"); flash() }
    @objc func label()    { run("label"); flash() }
    @objc func standup()  { terminal("standup") }
    @objc func toggleAuto() { autoTile.toggle() }
    @objc func quit()     { NSApp.terminate(nil) }

    func run(_ cmd: String) {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/bin/bash")
        t.arguments = ["-lc", "td \(cmd)"]
        try? t.run()
    }

    func terminal(_ cmd: String) {
        let src = """
        tell application "iTerm2"
            activate
            tell current window
                create tab with default profile
                tell current session of current tab
                    write text "td \(cmd)"
                end tell
            end tell
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
    }

    var isAnimating = false

    func flash() {
        guard let button = statusItem.button, !isAnimating else { return }
        isAnimating = true

        let origImage = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "td")
        origImage?.size = NSSize(width: 16, height: 16)

        // Pulse: fade out → checkmark → fade back
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            button.animator().alphaValue = 0.0
        }, completionHandler: {
            button.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "done")
            button.image?.size = NSSize(width: 16, height: 16)

            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                button.animator().alphaValue = 1.0
            }, completionHandler: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSAnimationContext.runAnimationGroup({ ctx in
                        ctx.duration = 0.15
                        button.animator().alphaValue = 0.0
                    }, completionHandler: {
                        button.image = origImage
                        NSAnimationContext.runAnimationGroup({ ctx in
                            ctx.duration = 0.15
                            button.animator().alphaValue = 1.0
                        }, completionHandler: {
                            self.isAnimating = false
                        })
                    })
                }
            })
        })
    }
}

let app = NSApplication.shared
let delegate = TD()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
