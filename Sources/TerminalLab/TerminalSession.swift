import AppKit
import SwiftTerm
import TerminalCore

@MainActor
private enum TerminalAppearance {
    static let foreground = NSColor(srgbRed: 0x29 / 255.0, green: 0xfe / 255.0, blue: 0x13 / 255.0, alpha: 1)
    static let background = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    static let selectionBackground = NSColor(srgbRed: 0x3a / 255.0, green: 0x3a / 255.0, blue: 0x3a / 255.0, alpha: 1)
    static let selectionForeground = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    static let ansiColors: [Color] = [
        Color(red8: 0x00, green8: 0x00, blue8: 0x00),
        Color(red8: 0xff, green8: 0x00, blue8: 0x00),
        Color(red8: 0x29, green8: 0xfe, blue8: 0x13),
        Color(red8: 0xae, green8: 0xad, blue8: 0x25),
        Color(red8: 0x53, green8: 0x2f, blue8: 0xe1),
        Color(red8: 0xb0, green8: 0x00, blue8: 0xff),
        Color(red8: 0x33, green8: 0xbb, blue8: 0xc7),
        Color(red8: 0xff, green8: 0xff, blue8: 0xff),
        Color(red8: 0x66, green8: 0x66, blue8: 0x66),
        Color(red8: 0xff, green8: 0x55, blue8: 0x55),
        Color(red8: 0x29, green8: 0xfe, blue8: 0x13),
        Color(red8: 0xae, green8: 0xad, blue8: 0x25),
        Color(red8: 0x53, green8: 0x2f, blue8: 0xe1),
        Color(red8: 0xcc, green8: 0x55, blue8: 0xff),
        Color(red8: 0x33, green8: 0xbb, blue8: 0xc7),
        Color(red8: 0xff, green8: 0xff, blue8: 0xff)
    ]
}

struct LaunchCommand {
    let executable: String
    let arguments: [String]
    let loginName: String?

    static func fromArguments(_ arguments: [String]) -> LaunchCommand {
        if arguments.count >= 2, arguments[0] == "--execute" {
            return LaunchCommand(executable: arguments[1], arguments: Array(arguments.dropFirst(2)), loginName: nil)
        }
        let shell: String
        if let account = getpwuid(getuid()), let path = account.pointee.pw_shell,
           FileManager.default.isExecutableFile(atPath: String(cString: path)) {
            shell = String(cString: path)
        } else {
            shell = "/bin/zsh"
        }
        return LaunchCommand(executable: shell, arguments: [], loginName: "-" + URL(fileURLWithPath: shell).lastPathComponent)
    }
}

@MainActor
final class TerminalSession: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
    let id: UUID
    let terminal: TabDanceTerminalView
    let activity: CodexActivityMonitor
    private(set) var isRunning = false
    var isBusy = false
    var onChange: ((String?, String?) -> Void)?
    private var stopping = false

    init(tab: TerminalTab, frame: NSRect, activity: CodexActivityMonitor) {
        id = tab.id
        self.activity = activity
        terminal = TabDanceTerminalView(frame: frame)
        super.init()
        terminal.font = NSFont(name: "Menlo", size: 20) ?? NSFont.monospacedSystemFont(ofSize: 20, weight: .regular)
        terminal.nativeForegroundColor = TerminalAppearance.foreground
        terminal.nativeBackgroundColor = TerminalAppearance.background
        terminal.caretColor = TerminalAppearance.foreground
        terminal.selectedTextBackgroundColor = TerminalAppearance.selectionBackground
        terminal.selectedTextForegroundColor = TerminalAppearance.selectionForeground
        terminal.installColors(TerminalAppearance.ansiColors)
        terminal.processDelegate = self
        terminal.onUserInput = { [weak self] bytes in
            guard let self, self.isRunning else { return }
            let bytes = Array(bytes)
            let pid = self.terminal.process.shellPid
            Task { await self.activity.noteUserInput(bytes, shellPID: pid) }
        }
    }

    func start(command: LaunchCommand, directory: String) {
        var isDirectory: ObjCBool = false
        let directory = FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) && isDirectory.boolValue
            ? directory : FileManager.default.homeDirectoryForCurrentUser.path
        terminal.startProcess(executable: command.executable, args: command.arguments,
                              execName: command.loginName, currentDirectory: directory)
        isRunning = terminal.process.running
        if !isRunning { terminal.feed(text: "Could not start \(command.executable).\r\n") }
        onChange?(directory, nil)
    }

    func stop() {
        stopping = true
        isBusy = false
        if isRunning {
            isRunning = false
            terminal.terminate()
        }
        terminal.processDelegate = nil
        terminal.onUserInput = nil
        onChange = nil
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        onChange?(nil, title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = URL(string: directory), url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost" || url.host == ProcessInfo.processInfo.hostName else { return }
        onChange?(url.path, nil)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isRunning = false
        isBusy = false
        guard !stopping else { return }
        let status: String
        if let rawStatus = exitCode {
            let signal = rawStatus & 0x7f
            status = signal == 0 ? "Process exited (status \(rawStatus >> 8))." : "Process ended (signal \(signal))."
        } else {
            status = "Process exited."
        }
        terminal.feed(text: "\r\n[\(status)]\r\n")
        onChange?(nil, nil)
    }
}
