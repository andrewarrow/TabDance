import AppKit
import SwiftTerm

private struct LaunchCommand {
    let executable: String
    let arguments: [String]
    let loginName: String?

    static func fromArguments(_ arguments: [String]) -> LaunchCommand {
        if arguments.count >= 2, arguments[0] == "--execute" {
            return LaunchCommand(executable: arguments[1], arguments: Array(arguments.dropFirst(2)), loginName: nil)
        }
        let shell = loginShell()
        return LaunchCommand(executable: shell, arguments: [], loginName: "-" + URL(fileURLWithPath: shell).lastPathComponent)
    }

    private static func loginShell() -> String {
        if let account = getpwuid(getuid()), let shell = account.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "/bin/zsh"
    }
}

private final class TerminalWindowController: NSWindowController, NSWindowDelegate, @preconcurrency LocalProcessTerminalViewDelegate {
    private let terminal: LocalProcessTerminalView
    private var shellRunning = false
    private var closing = false

    init(command: LaunchCommand) {
        let frame = NSRect(x: 0, y: 0, width: 900, height: 580)
        terminal = LocalProcessTerminalView(frame: frame)
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.autoresizingMask = [.width, .height]
        terminal.nativeForegroundColor = .textColor
        terminal.nativeBackgroundColor = .textBackgroundColor

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TerminalLab"
        window.minSize = NSSize(width: 360, height: 200)
        window.center()
        window.contentView = terminal
        super.init(window: window)
        window.delegate = self
        terminal.processDelegate = self
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminal)

        terminal.startProcess(
            executable: command.executable,
            args: command.arguments,
            execName: command.loginName,
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
        shellRunning = terminal.process.running
        if !shellRunning {
            terminal.feed(text: "Could not start \(command.executable).\r\n")
        }
    }

    required init?(coder: NSCoder) { nil }

    var isRunning: Bool { shellRunning }

    func stopSession() {
        guard shellRunning else { return }
        shellRunning = false
        terminal.terminate()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shellRunning, !closing else { return true }
        let alert = NSAlert()
        alert.messageText = "Close this terminal?"
        alert.informativeText = "A shell or command is still running in this window."
        alert.addButton(withTitle: "Cancel")
        let closeButton = alert.addButton(withTitle: "Close Terminal")
        if #available(macOS 11.0, *) { closeButton.hasDestructiveAction = true }
        alert.alertStyle = .warning
        return alert.runModal() == .alertSecondButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        closing = true
        stopSession()
        terminal.processDelegate = nil
        (NSApp.delegate as? AppDelegate)?.remove(self)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        window?.title = title.isEmpty ? "TerminalLab" : title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = URL(string: directory), url.isFileURL else { return }
        window?.representedURL = url
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        shellRunning = false
        guard !closing else { return }
        let status: String
        if let rawStatus = exitCode {
            let signal = rawStatus & 0x7f
            status = signal == 0
                ? "Process exited (status \(rawStatus >> 8))."
                : "Process ended (signal \(signal))."
        } else {
            status = "Process exited."
        }
        terminal.feed(text: "\r\n[\(status)]\r\n")
        window?.title = "TerminalLab — Exited"
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [TerminalWindowController] = []
    private let command = LaunchCommand.fromArguments(Array(CommandLine.arguments.dropFirst()))

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
        alert.messageText = "Quit TerminalLab?"
        alert.informativeText = "Running shells and commands in all windows will end."
        alert.addButton(withTitle: "Cancel")
        let quitButton = alert.addButton(withTitle: "Quit TerminalLab")
        if #available(macOS 11.0, *) { quitButton.hasDestructiveAction = true }
        alert.alertStyle = .warning
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        windows.forEach { $0.stopSession() }
    }

    func remove(_ controller: TerminalWindowController) {
        windows.removeAll { $0 === controller }
    }

    @objc private func newWindow(_ sender: Any?) {
        let controller = TerminalWindowController(command: command)
        windows.append(controller)
    }

    private func installMenus() {
        let menu = NSMenu()
        NSApp.mainMenu = menu

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit TerminalLab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let shellItem = NSMenuItem()
        let shellMenu = NSMenu(title: "Shell")
        let newItem = shellMenu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        newItem.target = self
        shellMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        shellItem.submenu = shellMenu
        menu.addItem(shellItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
    }
}

private let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()
