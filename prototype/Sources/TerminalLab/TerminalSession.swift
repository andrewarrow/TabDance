import AppKit
import SwiftTerm
import TerminalCore

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
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.nativeForegroundColor = .textColor
        terminal.nativeBackgroundColor = .textBackgroundColor
        terminal.selectedTextBackgroundColor = .selectedTextBackgroundColor
        terminal.selectedTextForegroundColor = .selectedTextColor
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
