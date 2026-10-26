import AppKit
import SwiftTerm
import TerminalCore
import XCTest
@testable import TerminalLab

@MainActor
private final class TestDraggingInfo: NSObject, NSDraggingInfo {
    weak var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .move
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("tabdance-test-\(UUID().uuidString)"))
    var draggingSource: Any?
    var draggingSequenceNumber: Int = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight = .none

    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey : Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}

@MainActor
final class WindowTests: XCTestCase {
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func shellArguments(_ input: String, executable: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-c", "set -- \(input); printf '%s\\0' \"$@\""]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(executable) failed to parse the dropped paths")
        return String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
    }

    func testPlainQuestionSelectionStaysLocalAndOptionDragReachesPTY() async throws {
        _ = NSApplication.shared
        let capture = FileManager.default.temporaryDirectory.appendingPathComponent("tabdance-mouse-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: capture) }
        let command = LaunchCommand(executable: "/bin/sh", arguments: ["-c", """
            stty raw -echo
            printf '\\033[?1002h\\033[?1006h\\033[3;1Hcopy this question\\r\\nREADY'
            cat > "$1"
            """, "mouse-fixture", capture.path], loginName: nil)
        let controller = TerminalWindowController(command: command, stateURL: nil)
        defer { controller.stopSessions(); controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        let view = try XCTUnwrap(window.firstResponder as? TabDanceTerminalView)

        func waitUntil(_ description: String, _ condition: () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Timed out waiting for \(description)")
        }
        func capturedInput() -> String {
            (try? String(contentsOf: capture, encoding: .utf8)) ?? ""
        }
        func dispatch(_ type: NSEvent.EventType, col: Int, modifiers: NSEvent.ModifierFlags = []) throws {
            let size = view.getWindowSize()
            let cellWidth = CGFloat(size.ws_xpixel) / window.backingScaleFactor / CGFloat(view.terminal.cols)
            let cellHeight = view.getOptimalFrameSize().height / CGFloat(view.terminal.rows)
            let point = NSPoint(x: (CGFloat(col) + 0.25) * cellWidth,
                                y: view.bounds.height - 2.5 * cellHeight)
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: view.convert(point, to: nil), modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
            ))
            let content = try XCTUnwrap(window.contentView)
            XCTAssertTrue(content.hitTest(view.convert(point, to: content.superview)) === view)
            // XCTest does not make this window key; send to the hit-tested
            // responder without depending on AppKit's first-click activation.
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            case .leftMouseUp: view.mouseUp(with: event)
            default: XCTFail("Unexpected mouse event")
            }
        }

        try await waitUntil("question from PTY") {
            String(decoding: view.terminal.getBufferAsData(), as: UTF8.self).contains("READY")
        }
        XCTAssertEqual(view.terminal.mouseMode, .buttonEventTracking)
        try dispatch(.leftMouseDown, col: 5)
        try dispatch(.leftMouseDragged, col: 9, modifiers: .option)
        try dispatch(.leftMouseUp, col: 9)
        XCTAssertEqual(view.copyText, "this")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "this")

        // A PTY screen switch clears the range, but must not turn the rest of
        // a local gesture into application motion/release events.
        try dispatch(.leftMouseDown, col: 5)
        view.dataReceived(slice: Array("\u{1B}[?1049h\u{1B}[3;1Hcopy this question".utf8)[...])
        try dispatch(.leftMouseDragged, col: 9)
        view.clearSelection()
        try dispatch(.leftMouseUp, col: 9, modifiers: .option)
        view.process.send(data: Array("LOCAL_DONE".utf8)[...])
        try await waitUntil("local gesture marker") { capturedInput().contains("LOCAL_DONE") }
        XCTAssertEqual(capturedInput(), "LOCAL_DONE", "Text selection must not send mouse reports to the child")

        try dispatch(.leftMouseDown, col: 5, modifiers: .option)
        try dispatch(.leftMouseDragged, col: 9, modifiers: .option)
        try dispatch(.leftMouseUp, col: 9, modifiers: .option)
        view.process.send(data: Array("OPTION_DONE".utf8)[...])
        try await waitUntil("application gesture marker") { capturedInput().contains("OPTION_DONE") }
        XCTAssertEqual(capturedInput(), "LOCAL_DONE\u{1B}[<8;6;3M\u{1B}[<40;10;3M\u{1B}[<8;10;3mOPTION_DONE")
        XCTAssertNil(view.copyText)
        XCTAssertTrue(view.allowMouseReporting)
    }

    func testFileDropsInsertEscapedPathsAsBracketedUserInputAndSelectTabTarget() throws {
        _ = NSApplication.shared
        let command = LaunchCommand(executable: "/bin/sh", arguments: ["-c", "read reply"], loginName: nil)
        let controller = TerminalWindowController(command: command, stateURL: nil)
        defer { controller.stopSessions(); controller.window?.close() }
        controller.newTab(nil)

        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let terminals = descendants(of: content).compactMap { $0 as? TabDanceTerminalView }
        let first = try XCTUnwrap(terminals.first)
        let second = try XCTUnwrap(terminals.last)
        let initialTabIDs = descendants(of: content).compactMap { ($0 as? TerminalTabView)?.tabID }
        let firstTab = try XCTUnwrap(descendants(of: content).compactMap { $0 as? TerminalTabView }.first)
        XCTAssertTrue(first.registeredDraggedTypes.contains(.fileURL))
        XCTAssertTrue(firstTab.registeredDraggedTypes.contains(.fileURL))

        first.feed(text: "selected text")
        first.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 8, row: 0))
        first.feed(text: "\u{1B}[?2004h")
        XCTAssertTrue(first.terminal.bracketedPasteMode)
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        clipboard.setString("clipboard stays", forType: .string)
        var observed: [[UInt8]] = []
        first.onUserInput = { observed.append(Array($0)) }

        let paths = [
            "/tmp/Tab Dance/one's [file] 💃.txt",
            "/tmp/Tab Dance/two; $(printf injected) ^! =.log"
        ]
        let info = TestDraggingInfo()
        info.draggingDestinationWindow = window
        info.draggingSourceOperationMask = .copy
        info.draggingPasteboard.writeObjects(paths.enumerated().map { index, path in
            NSURL(fileURLWithPath: path, isDirectory: index == 1)
        })
        let labelPoint = firstTab.convert(NSPoint(x: 24, y: firstTab.bounds.midY), to: nil)
        info.draggingLocation = labelPoint
        XCTAssertEqual(firstTab.draggingEntered(info), .copy)
        XCTAssertTrue(firstTab.prepareForDragOperation(info))
        XCTAssertTrue(window.firstResponder === second, "Hovering a tab must not select it")
        XCTAssertTrue(observed.isEmpty, "Preparing a drop must not send terminal input")
        XCTAssertTrue(firstTab.performDragOperation(info))
        XCTAssertEqual(observed.count, 1, "A multi-file drop is one paste transaction")

        XCTAssertTrue(window.firstResponder === first)
        XCTAssertNil(first.copyText, "A successful drop clears the previous selection")
        XCTAssertEqual(clipboard.string(forType: .string), "clipboard stays")
        XCTAssertEqual(descendants(of: content).compactMap { ($0 as? TerminalTabView)?.tabID }, initialTabIDs,
                       "A file drop must not reorder tabs")
        XCTAssertEqual(Set(terminals.compactMap { $0.process.running ? $0.process.shellPid : nil }),
                       Set([first.process.shellPid, second.process.shellPid]))
        let firstInput = String(decoding: try XCTUnwrap(observed.first), as: UTF8.self)
        XCTAssertTrue(firstInput.hasPrefix("\u{1B}[200~"))
        XCTAssertTrue(firstInput.hasSuffix("\u{1B}[201~"))
        let pastedText = String(firstInput.dropFirst("\u{1B}[200~".count).dropLast("\u{1B}[201~".count))
        XCTAssertTrue(pastedText.hasSuffix(" "))
        XCTAssertFalse(pastedText.contains("\n") || pastedText.contains("\r"), "Dropping paths must not press Enter")
        XCTAssertEqual(try shellArguments(pastedText, executable: "/bin/sh"), paths)
        XCTAssertEqual(try shellArguments(pastedText, executable: "/bin/zsh"), paths)

        let contentDrop = TestDraggingInfo()
        contentDrop.draggingDestinationWindow = window
        contentDrop.draggingSourceOperationMask = .copy
        contentDrop.draggingPasteboard.writeObjects([NSURL(fileURLWithPath: "/tmp/a b")])
        XCTAssertEqual(first.draggingEntered(contentDrop), .copy)
        XCTAssertTrue(first.prepareForDragOperation(contentDrop))
        first.feed(text: "\u{1B}[?2004l")
        XCTAssertTrue(first.performDragOperation(contentDrop))
        XCTAssertEqual(observed.count, 2)
        XCTAssertEqual(String(decoding: try XCTUnwrap(observed.last), as: UTF8.self), "/tmp/a\\ b ")
        XCTAssertEqual(clipboard.string(forType: .string), "clipboard stays")
    }

    func testFileDropRejectsNonFilesControlCharactersAndUnavailableTargets() throws {
        _ = NSApplication.shared
        let command = LaunchCommand(executable: "/bin/sh", arguments: ["-c", "read reply"], loginName: nil)
        let controller = TerminalWindowController(command: command, stateURL: nil)
        defer { controller.stopSessions(); controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        let terminal = try XCTUnwrap(window.firstResponder as? TabDanceTerminalView)
        var observed = 0
        terminal.onUserInput = { _ in observed += 1 }

        func checkRejected(_ setup: (TestDraggingInfo) -> Void) {
            let info = TestDraggingInfo()
            setup(info)
            XCTAssertEqual(terminal.draggingEntered(info), [])
            XCTAssertFalse(terminal.prepareForDragOperation(info))
            XCTAssertFalse(terminal.performDragOperation(info))
        }
        checkRejected { info in
            info.draggingPasteboard.setString("not a file", forType: .string)
            info.draggingSourceOperationMask = .copy
        }
        checkRejected { info in
            info.draggingPasteboard.writeObjects([NSURL(string: "https://example.com/file")!])
            info.draggingSourceOperationMask = .copy
        }
        checkRejected { info in
            info.draggingPasteboard.writeObjects([NSURL(string: "file://server/share/file")!])
            info.draggingSourceOperationMask = .copy
        }
        checkRejected { info in
            info.draggingPasteboard.setString("not a serialized URL", forType: .fileURL)
            info.draggingSourceOperationMask = .copy
        }
        checkRejected { info in
            info.draggingPasteboard.writeObjects([NSURL(fileURLWithPath: "/tmp/line\nbreak")])
            info.draggingSourceOperationMask = .copy
        }
        checkRejected { info in
            info.draggingPasteboard.writeObjects([NSURL(fileURLWithPath: "/tmp/file")])
            info.draggingSourceOperationMask = .move
        }
        terminal.process.terminate()
        checkRejected { info in
            info.draggingPasteboard.writeObjects([NSURL(fileURLWithPath: "/tmp/file")])
            info.draggingSourceOperationMask = .copy
        }
        XCTAssertEqual(observed, 0)
    }

    func testTabDropReordersWithinWindowAndPreservesShellAndSelection() throws {
        _ = NSApplication.shared
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("tabdance-drag-\(UUID().uuidString)/workspaces.json")
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let command = LaunchCommand(executable: "/bin/sh", arguments: ["-c", "read reply"], loginName: nil)
        let controller = TerminalWindowController(command: command, stateURL: stateURL)
        defer { controller.stopSessions(); controller.window?.close() }
        controller.newTab(nil)
        controller.newTab(nil)
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        controller.saveNow()
        let initial = try XCTUnwrap(WorkspaceLayout.restore(from: Data(contentsOf: stateURL)))
        let tabViews = descendants(of: content).compactMap { $0 as? TerminalTabView }
        let bar = try XCTUnwrap(descendants(of: content).compactMap { $0 as? TabBarScrollView }.first)
        let terminal = try XCTUnwrap(window.firstResponder as? TabDanceTerminalView)
        let pids = Set(descendants(of: content).compactMap { ($0 as? TabDanceTerminalView)?.process.shellPid })
        XCTAssertEqual(tabViews.map(\.tabID), initial.activeWorkspace.tabs.map(\.id))
        XCTAssertEqual(tabViews.count, 3)
        for view in tabViews.dropFirst() {
            XCTAssertTrue(view.hitTest(NSPoint(x: view.frame.midX - 20, y: view.frame.midY)) === view)
            XCTAssertTrue(view.hitTest(NSPoint(x: view.closeButton.frame.midX + view.frame.minX,
                                               y: view.closeButton.frame.midY + view.frame.minY)) === view.closeButton)
        }

        let info = TestDraggingInfo()
        info.draggingDestinationWindow = window
        info.draggingSource = tabViews[0]
        info.draggingPasteboard.setString(tabViews[0].tabID.uuidString, forType: bar.tabDragType)
        info.draggingLocation = bar.convert(NSPoint(x: bar.bounds.maxX - 2, y: bar.bounds.midY), to: nil)
        XCTAssertEqual(bar.draggingEntered(info), .move)
        XCTAssertTrue(bar.performDragOperation(info))
        controller.saveNow()
        let moved = try XCTUnwrap(WorkspaceLayout.restore(from: Data(contentsOf: stateURL)))
        XCTAssertEqual(moved.activeWorkspace.tabs.map(\.id), [initial.activeWorkspace.tabs[1].id, initial.activeWorkspace.tabs[2].id, initial.activeWorkspace.tabs[0].id])
        XCTAssertEqual(moved.selectedTab.id, initial.selectedTab.id)
        XCTAssertTrue(window.firstResponder === terminal)
        XCTAssertEqual(Set(descendants(of: content).compactMap { ($0 as? TabDanceTerminalView)?.process.shellPid }), pids)

        info.draggingSource = try XCTUnwrap(descendants(of: content).compactMap { $0 as? TerminalTabView }.last)
        info.draggingPasteboard.setString(initial.activeWorkspace.tabs[0].id.uuidString, forType: bar.tabDragType)
        info.draggingLocation = bar.convert(NSPoint(x: 1, y: bar.bounds.midY), to: nil)
        XCTAssertEqual(bar.draggingUpdated(info), .move)
        XCTAssertTrue(bar.performDragOperation(info))
        controller.saveNow()
        XCTAssertEqual(WorkspaceLayout.restore(from: try Data(contentsOf: stateURL))?.activeWorkspace.tabs.map(\.id), initial.activeWorkspace.tabs.map(\.id))

        info.draggingPasteboard.setString(UUID().uuidString, forType: bar.tabDragType)
        XCTAssertEqual(bar.draggingUpdated(info), [])
        XCTAssertFalse(bar.performDragOperation(info))

        let otherController = TerminalWindowController(command: command, stateURL: nil)
        defer { otherController.stopSessions(); otherController.window?.close() }
        let otherBar = try XCTUnwrap(descendants(of: try XCTUnwrap(otherController.window?.contentView)).compactMap { $0 as? TabBarScrollView }.first)
        info.draggingPasteboard.setString(initial.activeWorkspace.tabs[0].id.uuidString, forType: bar.tabDragType)
        XCTAssertEqual(otherBar.draggingEntered(info), [])
        XCTAssertFalse(otherBar.performDragOperation(info))

        controller.newWorkspace(nil)
        XCTAssertEqual(bar.draggingEntered(info), [])
        XCTAssertFalse(bar.performDragOperation(info))
    }

    func testWorkspaceDropReordersRowsWithoutChangingLiveSelection() throws {
        _ = NSApplication.shared
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("tabdance-workspace-drag-\(UUID().uuidString)/workspaces.json")
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let command = LaunchCommand(executable: "/bin/sh", arguments: ["-c", "read reply"], loginName: nil)
        let controller = TerminalWindowController(command: command, stateURL: stateURL)
        defer { controller.stopSessions(); controller.window?.close() }
        controller.newWorkspace(nil)
        controller.newWorkspace(nil)
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        let table = try XCTUnwrap(descendants(of: content).compactMap { $0 as? NSTableView }.first)
        let terminal = try XCTUnwrap(window.firstResponder as? TabDanceTerminalView)
        let pids = Set(descendants(of: content).compactMap { ($0 as? TabDanceTerminalView)?.process.shellPid })
        controller.saveNow()
        let initial = try XCTUnwrap(WorkspaceLayout.restore(from: Data(contentsOf: stateURL)))
        let info = TestDraggingInfo()
        info.draggingDestinationWindow = window
        info.draggingSource = table
        let type = NSPasteboard.PasteboardType("dev.tabdance.workspace")
        info.draggingPasteboard.setString(initial.workspaces[0].id.uuidString, forType: type)
        XCTAssertEqual(controller.tableView(table, validateDrop: info, proposedRow: 3, proposedDropOperation: .above), .move)
        XCTAssertTrue(controller.tableView(table, acceptDrop: info, row: 3, dropOperation: .above))
        controller.saveNow()
        let moved = try XCTUnwrap(WorkspaceLayout.restore(from: Data(contentsOf: stateURL)))
        XCTAssertEqual(moved.workspaces.map(\.id), [initial.workspaces[1].id, initial.workspaces[2].id, initial.workspaces[0].id])
        XCTAssertEqual(moved.activeWorkspaceID, initial.activeWorkspaceID)
        XCTAssertEqual(moved.selectedTab.id, initial.selectedTab.id)
        XCTAssertTrue(window.firstResponder === terminal)
        XCTAssertEqual(Set(descendants(of: content).compactMap { ($0 as? TabDanceTerminalView)?.process.shellPid }), pids)
        XCTAssertEqual(controller.tableView(table, validateDrop: info, proposedRow: 9, proposedDropOperation: .above), [])
        XCTAssertFalse(controller.tableView(table, acceptDrop: info, row: 9, dropOperation: .above))
        info.draggingPasteboard.setString(UUID().uuidString, forType: type)
        XCTAssertEqual(controller.tableView(table, validateDrop: info, proposedRow: 0, proposedDropOperation: .above), [])
        XCTAssertFalse(controller.tableView(table, acceptDrop: info, row: 0, dropOperation: .above))
    }

    func testTabDropAtEdgeScrollsAndClearsInsertionMarker() throws {
        _ = NSApplication.shared
        let command = LaunchCommand(executable: "/bin/sh", arguments: ["-c", "read reply"], loginName: nil)
        let controller = TerminalWindowController(command: command, stateURL: nil)
        defer { controller.stopSessions(); controller.window?.close() }
        for _ in 0..<7 { controller.newTab(nil) }
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 390, height: 844))
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let bar = try XCTUnwrap(descendants(of: content).compactMap { $0 as? TabBarScrollView }.first)
        let source = try XCTUnwrap(descendants(of: content).compactMap { $0 as? TerminalTabView }.first)
        bar.contentView.scroll(to: .zero)
        bar.reflectScrolledClipView(bar.contentView)
        let marker = try XCTUnwrap(bar.contentView.subviews.first { $0 !== bar.documentView })
        XCTAssertTrue(marker.isHidden)
        let info = TestDraggingInfo()
        info.draggingDestinationWindow = window
        info.draggingSource = source
        info.draggingPasteboard.setString(source.tabID.uuidString, forType: bar.tabDragType)
        info.draggingLocation = bar.convert(NSPoint(x: bar.bounds.maxX - 2, y: bar.bounds.midY), to: nil)
        for _ in 0..<5 { XCTAssertEqual(bar.draggingUpdated(info), .move) }
        XCTAssertGreaterThan(bar.contentView.bounds.origin.x, 0)
        XCTAssertFalse(marker.isHidden)
        XCTAssertTrue(bar.contentView.bounds.contains(marker.frame))
        if let directory = ProcessInfo.processInfo.environment["TABDANCE_SCREENSHOT_DIR"] {
            bar.displayIfNeeded()
            let image = try XCTUnwrap(bar.bitmapImageRepForCachingDisplay(in: bar.bounds))
            bar.cacheDisplay(in: bar.bounds, to: image)
            let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("tabdance-drag-marker.png"))
        }
        bar.draggingExited(info)
        XCTAssertTrue(marker.isHidden)
    }

    func testTabLabelClickStillSelectsWhileCloseButtonKeepsItsTarget() throws {
        _ = NSApplication.shared
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("tabdance-tab-click-\(UUID().uuidString)/workspaces.json")
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let controller = TerminalWindowController(command: LaunchCommand(executable: "/bin/sh", arguments: ["-c", "read reply"], loginName: nil), stateURL: stateURL)
        defer { controller.stopSessions(); controller.window?.close() }
        controller.newTab(nil)
        controller.newTab(nil)
        let window = try XCTUnwrap(controller.window)
        let tabViews = descendants(of: try XCTUnwrap(window.contentView)).compactMap { $0 as? TerminalTabView }
        let second = try XCTUnwrap(tabViews.dropFirst().first)
        let third = try XCTUnwrap(tabViews.last)
        let labelPoint = NSPoint(x: 20, y: second.bounds.midY)
        let closePoint = NSPoint(x: second.closeButton.frame.midX, y: second.closeButton.frame.midY)
        XCTAssertTrue(second.hitTest(second.convert(labelPoint, to: second.superview)) === second)
        XCTAssertTrue(second.hitTest(second.convert(closePoint, to: second.superview)) === second.closeButton)
        let windowPoint = second.convert(labelPoint, to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint, modifierFlags: [],
                                                   timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                   eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: windowPoint, modifierFlags: [],
                                                 timestamp: 0.1, windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 2, clickCount: 1, pressure: 0))
        let smallDrag = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged,
                                                        location: NSPoint(x: windowPoint.x + 2, y: windowPoint.y),
                                                        modifierFlags: [], timestamp: 0.05, windowNumber: window.windowNumber,
                                                        context: nil, eventNumber: 3, clickCount: 1, pressure: 1))
        var selections = 0
        let originalSelection = second.selectButton.onPress
        second.selectButton.onPress = { selections += 1; originalSelection?() }
        second.mouseDown(with: down)
        second.mouseDragged(with: smallDrag)
        second.mouseUp(with: up)
        XCTAssertEqual(selections, 1)
        controller.saveNow()
        let saved = try XCTUnwrap(WorkspaceLayout.restore(from: Data(contentsOf: stateURL)))
        XCTAssertEqual(saved.selectedTab.id, second.tabID)
        XCTAssertTrue(window.firstResponder is TabDanceTerminalView)

        let thirdPoint = third.convert(NSPoint(x: 20, y: third.bounds.midY), to: nil)
        let thirdDown = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: thirdPoint, modifierFlags: [],
                                                        timestamp: 0.2, windowNumber: window.windowNumber, context: nil,
                                                        eventNumber: 4, clickCount: 1, pressure: 1))
        let outsideUp = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp,
                                                        location: NSPoint(x: thirdPoint.x, y: thirdPoint.y + 60),
                                                        modifierFlags: [], timestamp: 0.3, windowNumber: window.windowNumber,
                                                        context: nil, eventNumber: 5, clickCount: 1, pressure: 0))
        third.mouseDown(with: thirdDown)
        third.mouseUp(with: outsideUp)
        controller.saveNow()
        XCTAssertEqual(WorkspaceLayout.restore(from: try Data(contentsOf: stateURL))?.selectedTab.id, second.tabID)
    }

    func testBackgroundCodexUpdatesKeepTabClicksAndWorkspaceActivity() throws {
        _ = NSApplication.shared
        let controller = TerminalWindowController(command: LaunchCommand(executable: "/bin/sh", arguments: ["-c", "read reply"], loginName: nil), stateURL: nil)
        defer { controller.stopSessions(); controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        let first = try XCTUnwrap(window.firstResponder as? TabDanceTerminalView)
        let session = try XCTUnwrap(first.processDelegate as? TerminalSession)
        let firstPID = first.process.shellPid
        session.isBusy = true
        first.feed(text: "\u{1B}]0;Codex working\u{7}")
        controller.newTab(nil)
        let second = try XCTUnwrap(window.firstResponder as? TabDanceTerminalView)
        controller.newWorkspace(nil)
        content.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(descendants(of: content).compactMap { $0 as? NSTableView }.first)
        let busyWorkspace = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? WorkspaceCell)
        let idleWorkspace = try XCTUnwrap(table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? WorkspaceCell)
        XCTAssertFalse(busyWorkspace.spinner.isHidden)
        XCTAssertTrue(idleWorkspace.spinner.isHidden)
        controller.previousWorkspace(nil)
        XCTAssertTrue(window.firstResponder === second)
        XCTAssertTrue(first.isHidden)
        content.layoutSubtreeIfNeeded()

        let tab = try XCTUnwrap(descendants(of: content).compactMap { $0 as? TerminalTabView }.first { $0.tabID == session.id })
        let point = tab.convert(NSPoint(x: 20, y: tab.bounds.midY), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                   timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                   eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                                 timestamp: 0.1, windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 2, clickCount: 1, pressure: 0))
        tab.mouseDown(with: down)
        first.feed(text: "\u{1B}]0;Codex still working\u{7}\u{1B}]7;file://localhost/tmp/codex-project\u{7}")
        content.layoutSubtreeIfNeeded()
        let currentTab = try XCTUnwrap(descendants(of: content).compactMap { $0 as? TerminalTabView }.first { $0.tabID == session.id })
        XCTAssertTrue(currentTab === tab, "Background title and directory updates must preserve an in-progress click")
        XCTAssertEqual(currentTab.selectButton.title, "codex-project")
        XCTAssertEqual(currentTab.selectButton.toolTip, "/tmp/codex-project\nCodex still working")
        XCTAssertEqual(currentTab.closeButton.toolTip, "Close codex-project")
        currentTab.mouseUp(with: up)
        XCTAssertTrue(window.firstResponder === first)
        XCTAssertFalse(first.isHidden)
        XCTAssertTrue(second.isHidden)
        XCTAssertEqual(first.process.shellPid, firstPID)
        XCTAssertTrue(first.process.running)
        XCTAssertTrue(session.isBusy)
        XCTAssertEqual(currentTab.selectButton.font, NSFont.systemFont(ofSize: 12, weight: .semibold))
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? WorkspaceCell)
        XCTAssertFalse(cell.spinner.isHidden)
        controller.nextTab(nil)
        XCTAssertTrue(window.firstResponder === second)
        XCTAssertEqual(currentTab.selectButton.font, NSFont.systemFont(ofSize: 12, weight: .regular))
        session.isBusy = false
        first.feed(text: "\u{1B}]0;Codex complete\u{7}")
        let completedCell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? WorkspaceCell)
        XCTAssertTrue(completedCell.spinner.isHidden)
    }

    func testBackgroundTitleUpdatesPreserveTabBarScrollPosition() throws {
        _ = NSApplication.shared
        let controller = TerminalWindowController(command: LaunchCommand(executable: "/bin/sh", arguments: ["-c", "read reply"], loginName: nil), stateURL: nil)
        defer { controller.stopSessions(); controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        let first = try XCTUnwrap(window.firstResponder as? TabDanceTerminalView)
        for _ in 0..<7 { controller.newTab(nil) }
        content.layoutSubtreeIfNeeded()
        let selected = try XCTUnwrap(window.firstResponder as? TabDanceTerminalView)
        let bar = try XCTUnwrap(descendants(of: content).compactMap { $0 as? TabBarScrollView }.first)
        XCTAssertGreaterThan(bar.contentView.bounds.origin.x, 0)
        bar.contentView.scroll(to: .zero)
        bar.reflectScrolledClipView(bar.contentView)
        first.feed(text: "\u{1B}]0;Codex working in background\u{7}")
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.contentView.bounds.origin.x, 0)
        XCTAssertTrue(window.firstResponder === selected)
        controller.previousTab(nil)
        XCTAssertGreaterThan(bar.contentView.bounds.origin.x, 0, "Explicit navigation should still reveal the selected tab")
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

    func testClosingBottomWorkspacesWithSameDirectoryKeepsVisibleTerminalInSync() throws {
        _ = NSApplication.shared
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("tabdance-workspace-close-\(UUID().uuidString)/workspaces.json")
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let command = LaunchCommand(executable: "/bin/sh", arguments: ["-c", "read reply"], loginName: nil)
        let controller = TerminalWindowController(command: command, stateURL: stateURL)
        defer { controller.stopSessions(); controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        let first = try XCTUnwrap(window.firstResponder as? TabDanceTerminalView)
        controller.newTab(nil)
        let firstSelected = try XCTUnwrap(window.firstResponder as? TabDanceTerminalView)
        controller.newWorkspace(nil)
        let second = try XCTUnwrap(window.firstResponder as? TabDanceTerminalView)
        controller.newTab(nil)
        let secondSelected = try XCTUnwrap(window.firstResponder as? TabDanceTerminalView)
        controller.newWorkspace(nil)
        let third = try XCTUnwrap(window.firstResponder as? TabDanceTerminalView)
        controller.newWorkspace(nil)
        let fourth = try XCTUnwrap(window.firstResponder as? TabDanceTerminalView)
        let table = try XCTUnwrap(descendants(of: content).compactMap { $0 as? NSTableView }.first)
        controller.saveNow()
        let initial = try XCTUnwrap(WorkspaceLayout.restore(from: Data(contentsOf: stateURL)))
        XCTAssertEqual(initial.workspaces.count, 4)
        XCTAssertEqual(initial.workspaces[2].tabs[0].directory, initial.workspaces[3].tabs[0].directory)

        func assertSelection(row: Int, terminal: TabDanceTerminalView) throws {
            content.layoutSubtreeIfNeeded()
            controller.saveNow()
            let saved = try XCTUnwrap(WorkspaceLayout.restore(from: Data(contentsOf: stateURL)))
            XCTAssertEqual(saved.activeWorkspaceID, initial.workspaces[row].id)
            XCTAssertEqual(table.selectedRow, row)
            XCTAssertTrue(window.firstResponder === terminal)
            let visible = descendants(of: content).compactMap { $0 as? TabDanceTerminalView }.filter { !$0.isHidden }
            XCTAssertEqual(visible.count, 1, "Only the selected tab's terminal should be visible")
            XCTAssertTrue(visible.first === terminal)
            let tabViews = descendants(of: content).compactMap { $0 as? TerminalTabView }
            XCTAssertEqual(tabViews.map(\.tabID), saved.activeWorkspace.tabs.map(\.id))
            let selectedTab = try XCTUnwrap(tabViews.first { $0.tabID == saved.selectedTab.id })
            XCTAssertTrue(selectedTab.terminal === terminal)
            XCTAssertEqual(selectedTab.selectButton.font, NSFont.systemFont(ofSize: 12, weight: .semibold))
        }

        let closeButton = try XCTUnwrap(descendants(of: content).compactMap { $0 as? TerminalTabView }.first?.closeButton)
        closeButton.performClick(nil)
        XCTAssertNil(fourth.superview, "Closing a workspace must remove its terminal view")
        XCTAssertFalse(fourth.process.running)
        XCTAssertEqual(table.numberOfRows, 3)
        try assertSelection(row: 2, terminal: third)
        controller.closeSelectedTab(nil)
        XCTAssertNil(third.superview)
        XCTAssertFalse(third.process.running)
        XCTAssertEqual(table.numberOfRows, 2)
        try assertSelection(row: 1, terminal: secondSelected)
        XCTAssertEqual(descendants(of: content).compactMap { $0 as? TabDanceTerminalView }.count, 4)

        for (row, selected, other) in [(0, firstSelected, first), (1, secondSelected, second)] {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            try assertSelection(row: row, terminal: selected)
            let otherTab = try XCTUnwrap(descendants(of: content).compactMap { $0 as? TerminalTabView }.first { $0.terminal === other })
            otherTab.selectButton.performClick(nil)
            try assertSelection(row: row, terminal: other)
            XCTAssertTrue(selected.process.running)
            XCTAssertTrue(other.process.running)
        }
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
