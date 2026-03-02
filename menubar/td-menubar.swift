import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.title = "⌘td"
            button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        }

        let menu = NSMenu()

        let tileItem = NSMenuItem(title: "Tile Windows", action: #selector(tile), keyEquivalent: "t")
        tileItem.target = self
        menu.addItem(tileItem)

        let tileNoMain = NSMenuItem(title: "Tile (no browser)", action: #selector(tileNoMain), keyEquivalent: "")
        tileNoMain.target = self
        menu.addItem(tileNoMain)

        menu.addItem(NSMenuItem.separator())

        let labelItem = NSMenuItem(title: "Label Sessions", action: #selector(label), keyEquivalent: "l")
        labelItem.target = self
        menu.addItem(labelItem)

        let statusItem2 = NSMenuItem(title: "Status", action: #selector(status), keyEquivalent: "s")
        statusItem2.target = self
        menu.addItem(statusItem2)

        let standupItem = NSMenuItem(title: "Standup", action: #selector(standup), keyEquivalent: "")
        standupItem.target = self
        menu.addItem(standupItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc func tile() { runTd("tile") }
    @objc func tileNoMain() { runTd("tile --no-main") }
    @objc func label() { runTd("label") }
    @objc func status() { runInTerminal("status") }
    @objc func standup() { runInTerminal("standup") }
    @objc func quit() { NSApp.terminate(nil) }

    /// Run td command silently (no terminal output needed)
    func runTd(_ subcmd: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-lc", "td \(subcmd)"]
        try? task.run()
    }

    /// Run td command in a visible iTerm tab (for commands with output)
    func runInTerminal(_ subcmd: String) {
        let script = """
        tell application "iTerm2"
            activate
            tell current window
                create tab with default profile
                tell current session of current tab
                    write text "td \(subcmd)"
                end tell
            end tell
        end tell
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
