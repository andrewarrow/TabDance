import AppKit
import TerminalCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [TerminalWindowController] = []
    private let command = LaunchCommand.fromArguments(Array(CommandLine.arguments.dropFirst()))
    private let deterministicSession = CommandLine.arguments.contains("--execute")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMenus()
        newWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard windows.contains(where: \.isRunning) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit TabDance?"
        alert.informativeText = "Running shells and commands in all windows will end."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit TabDance").hasDestructiveAction = true
        alert.alertStyle = .warning
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        windows.forEach { $0.saveNow(); $0.stopSessions() }
    }

    func remove(_ controller: TerminalWindowController) { windows.removeAll { $0 === controller } }

    @objc private func newWindow(_ sender: Any?) {
        let stateURL: URL? = windows.isEmpty && !deterministicSession
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("TabDance/workspaces.json") : nil
        windows.append(TerminalWindowController(command: command, stateURL: stateURL))
    }

    func installMenus() {
        let menu = NSMenu()
        NSApp.mainMenu = menu
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            item.submenu = submenu
            menu.addItem(item)
            return submenu
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
                 modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, tag: Int = 0) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            item.tag = tag
        }
        let appMenu = submenu("TabDance")
        add(appMenu, "Quit TabDance", #selector(NSApplication.terminate(_:)), "q")
        let shellMenu = submenu("Shell")
        add(shellMenu, "New Tab", #selector(TerminalWindowController.newTab(_:)), "t")
        add(shellMenu, "New Workspace", #selector(TerminalWindowController.newWorkspace(_:)), "n", modifiers: [.command, .shift])
        add(shellMenu, "New Window", #selector(newWindow(_:)), "n", target: self)
        shellMenu.addItem(.separator())
        add(shellMenu, "Close Tab", #selector(TerminalWindowController.closeSelectedTab(_:)), "w")
        add(shellMenu, "Close Window", #selector(NSWindow.performClose(_:)), "w", modifiers: [.command, .shift])
        let editMenu = submenu("Edit")
        add(editMenu, "Copy", #selector(NSText.copy(_:)), "c")
        add(editMenu, "Paste", #selector(NSText.paste(_:)), "v")
        add(editMenu, "Select All", #selector(NSText.selectAll(_:)), "a")
        editMenu.addItem(.separator())
        add(editMenu, "Clear to Start", #selector(TabDanceTerminalView.clearToStart(_:)), "k")
        let viewMenu = submenu("View")
        add(viewMenu, "Toggle Workspace Sidebar", #selector(TerminalWindowController.toggleSidebar(_:)), "b")
        let navigateMenu = submenu("Navigate")
        add(navigateMenu, "Next Tab", #selector(TerminalWindowController.nextTab(_:)), "\t", modifiers: .control)
        add(navigateMenu, "Previous Tab", #selector(TerminalWindowController.previousTab(_:)), "\t", modifiers: [.control, .shift])
        add(navigateMenu, "Next Workspace", #selector(TerminalWindowController.nextWorkspace(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: [.command, .option])
        add(navigateMenu, "Previous Workspace", #selector(TerminalWindowController.previousWorkspace(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers: [.command, .option])
        navigateMenu.addItem(.separator())
        add(navigateMenu, "Move Tab Left", #selector(TerminalWindowController.moveTabLeft(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), modifiers: [.command, .control, .shift])
        add(navigateMenu, "Move Tab Right", #selector(TerminalWindowController.moveTabRight(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), modifiers: [.command, .control, .shift])
        navigateMenu.addItem(.separator())
        for number in 1...9 {
            add(navigateMenu, number == 9 ? "Select Last Tab" : "Select Tab \(number)", #selector(TerminalWindowController.selectTabNumber(_:)), String(number), tag: number)
        }
        let windowMenu = submenu("Window")
        add(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        NSApp.windowsMenu = windowMenu
    }
}

private let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()
