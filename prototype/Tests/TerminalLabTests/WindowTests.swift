import AppKit
import SwiftTerm
import TerminalCore
import XCTest
@testable import TerminalLab

@MainActor
final class WindowTests: XCTestCase {
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    func testWorkspaceSwitchingKeepsShellsAndRestoresFocus() {
        _ = NSApplication.shared
        let command = LaunchCommand(executable: "/bin/sh", arguments: ["-c", "read reply"], loginName: nil)
        let controller = TerminalWindowController(command: command, stateURL: nil)
        defer { controller.stopSessions(); controller.window?.close() }
        guard let window = controller.window, let content = window.contentView,
              let first = window.firstResponder as? TabDanceTerminalView else { return XCTFail("No focused terminal") }
        let firstPID = first.process.shellPid
        controller.newTab(nil)
        let second = window.firstResponder as? TabDanceTerminalView
        XCTAssertFalse(first === second)
        XCTAssertTrue(first.process.running)
        controller.previousTab(nil)
        XCTAssertTrue(window.firstResponder === first)
        XCTAssertEqual(first.process.shellPid, firstPID)
        controller.newWorkspace(nil)
        let other = window.firstResponder as? TabDanceTerminalView
        XCTAssertFalse(other === first)
        controller.previousWorkspace(nil)
        XCTAssertTrue(window.firstResponder === first)
        controller.nextTab(nil)
        XCTAssertTrue(window.firstResponder === second)
        XCTAssertEqual(descendants(of: content).compactMap { $0 as? TabDanceTerminalView }.count, 3)
        XCTAssertTrue(first.process.running)
        XCTAssertTrue(second?.process.running == true)
        XCTAssertTrue(other?.process.running == true)
    }

    func testWindowLayoutAtNarrowAndWideSizesKeepsTerminalWithinContent() throws {
        _ = NSApplication.shared
        let command = LaunchCommand(executable: "/bin/sh", arguments: ["-c", "read reply"], loginName: nil)
        let controller = TerminalWindowController(command: command, stateURL: nil)
        defer { controller.stopSessions(); controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        controller.newTab(nil)
        controller.newWorkspace(nil)
        controller.newTab(nil)
        let fixture = try XCTUnwrap(window.firstResponder as? TabDanceTerminalView)
        fixture.send(data: ArraySlice<UInt8>())
        fixture.feed(text: "\u{1B}]7;file://localhost/Users/aa/os/TabDance\u{7}\u{1B}]0;TabDance fixture\u{7}$ cat /tmp/tabdance-selection.txt\r\nalpha\r\nbeta\r\ngamma\r\n$ ")
        XCTAssertTrue(String(decoding: fixture.terminal.getBufferAsData(), as: UTF8.self).contains("alpha"))
        for size in [NSSize(width: 390, height: 844), NSSize(width: 768, height: 1024), NSSize(width: 1280, height: 800), NSSize(width: 1440, height: 900)] {
            window.setContentSize(size)
            content.layoutSubtreeIfNeeded()
            content.layoutSubtreeIfNeeded()
            let terminal = try XCTUnwrap(window.firstResponder as? TabDanceTerminalView)
            let rect = terminal.convert(terminal.bounds, to: content)
            XCTAssertGreaterThan(rect.width, content.bounds.width < 600 ? 340 : content.bounds.width - 170)
            XCTAssertGreaterThan(rect.height, content.bounds.height - 50)
            XCTAssertTrue(content.bounds.contains(rect), "Terminal \(rect) overflows content \(content.bounds) at \(size)")
            XCTAssertGreaterThan(terminal.terminal.cols, 20)
            XCTAssertGreaterThan(terminal.terminal.rows, 8)
            XCTAssertFalse(terminal.hasAmbiguousLayout)
            if let directory = ProcessInfo.processInfo.environment["TABDANCE_SCREENSHOT_DIR"] {
                terminal.needsDisplay = true
                terminal.display()
                window.displayIfNeeded()
                let image = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: image)
                // AppKit's parent cache omits the layer-backed terminal's contents.
                let terminalImage = try XCTUnwrap(terminal.bitmapImageRepForCachingDisplay(in: terminal.bounds))
                terminal.cacheDisplay(in: terminal.bounds, to: terminalImage)
                let composite = NSImage(size: content.bounds.size)
                composite.lockFocus()
                NSColor.windowBackgroundColor.setFill()
                content.bounds.fill()
                image.draw(in: content.bounds)
                terminal.nativeBackgroundColor.setFill()
                rect.fill()
                terminalImage.draw(in: rect)
                composite.unlockFocus()
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(composite.tiffRepresentation)))
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("tabdance-\(Int(size.width)).png"))
            }
        }
        controller.toggleSidebar(nil)
        content.layoutSubtreeIfNeeded()
        let terminal = try XCTUnwrap(window.firstResponder as? TabDanceTerminalView)
        XCTAssertGreaterThan(terminal.frame.width, 1400)
    }

    func testMenuCommandsReachTheFocusedWorkspaceAndTerminalThroughResponderChain() throws {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.installMenus()
        let controller = TerminalWindowController(command: LaunchCommand(executable: "/bin/sh", arguments: ["-c", "read reply"], loginName: nil), stateURL: nil)
        defer { controller.stopSessions(); controller.window?.close(); app.mainMenu = nil }
        let window = try XCTUnwrap(controller.window)
        let first = try XCTUnwrap(window.firstResponder as? TabDanceTerminalView)
        let menu = try XCTUnwrap(app.mainMenu)
        func press(_ character: String, modifiers: NSEvent.ModifierFlags) throws {
            let item = try XCTUnwrap(menu.items.flatMap { $0.submenu?.items ?? [] }.first {
                $0.keyEquivalent == character && $0.keyEquivalentModifierMask == modifiers
            })
            let action = try XCTUnwrap(item.action)
            // XCTest has no key window; dispatch through the actual window's
            // responder chain instead of NSApplication's global target lookup.
            XCTAssertTrue(window.firstResponder?.tryToPerform(action, with: item) == true)
        }
        try press("t", modifiers: .command)
        XCTAssertFalse(window.firstResponder === first)
        try press("1", modifiers: .command)
        XCTAssertTrue(window.firstResponder === first)
        first.feed(text: "old log\r\n$ partial")
        try press("k", modifiers: .command)
        XCTAssertFalse(String(decoding: first.terminal.getBufferAsData(), as: UTF8.self).contains("old log"))
        try press("a", modifiers: .command)
        XCTAssertTrue(first.copyText?.contains("$ partial") == true)
        try press("n", modifiers: [.command, .shift])
        XCTAssertFalse(window.firstResponder === first)
        controller.previousWorkspace(nil)
        XCTAssertTrue(window.firstResponder === first)
    }

    func testPrimaryWindowSavesAndRestoresWorkspaceLayout() throws {
        _ = NSApplication.shared
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("tabdance-window-\(UUID().uuidString)/workspaces.json")
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let command = LaunchCommand(executable: "/bin/sh", arguments: ["-c", "read reply"], loginName: nil)
        let controller = TerminalWindowController(command: command, stateURL: stateURL)
        controller.newTab(nil)
        controller.newWorkspace(nil)
        controller.saveNow()
        let saved = try XCTUnwrap(WorkspaceLayout.restore(from: Data(contentsOf: stateURL)))
        XCTAssertEqual(saved.workspaces.map { $0.tabs.count }, [2, 1])
        controller.stopSessions()
        controller.window?.close()
        let restored = TerminalWindowController(command: command, stateURL: stateURL)
        defer { restored.stopSessions(); restored.window?.close() }
        restored.saveNow()
        let result = try XCTUnwrap(WorkspaceLayout.restore(from: Data(contentsOf: stateURL)))
        XCTAssertEqual(result, saved)
        let terminals = descendants(of: try XCTUnwrap(restored.window?.contentView)).compactMap { $0 as? TabDanceTerminalView }
        XCTAssertEqual(terminals.count, 3)
        XCTAssertEqual(terminals.filter { !$0.isHidden }.count, 1)
    }

    func testNewTabInheritsShellDirectoryWithoutOSC7OrPolling() async throws {
        _ = NSApplication.shared
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("tabdance-cwd-\(UUID().uuidString)/workspaces.json")
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let command = LaunchCommand(executable: "/bin/sh", arguments: ["-c", "read command; eval \"$command\"; printf 'DIRECTORY_READY\\n'; read reply"], loginName: nil)
        let controller = TerminalWindowController(command: command, stateURL: stateURL)
        defer { controller.stopSessions(); controller.window?.close() }
        let first = try XCTUnwrap(controller.window?.firstResponder as? TabDanceTerminalView)
        first.send(txt: "cd /tmp\n")
        for _ in 0..<100 {
            if String(decoding: first.terminal.getBufferAsData(), as: UTF8.self).contains("DIRECTORY_READY") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(String(decoding: first.terminal.getBufferAsData(), as: UTF8.self).contains("DIRECTORY_READY"))
        controller.newTab(nil)
        controller.saveNow()
        let saved = try XCTUnwrap(WorkspaceLayout.restore(from: Data(contentsOf: stateURL)))
        XCTAssertEqual(URL(fileURLWithPath: saved.selectedTab.directory).resolvingSymlinksInPath().path,
                       URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().path)
    }
}
