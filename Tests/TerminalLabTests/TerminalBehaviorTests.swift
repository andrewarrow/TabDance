import AppKit
import XCTest
import SwiftTerm
import TerminalCore

@MainActor
final class TerminalBehaviorTests: XCTestCase {
    private func makeView(cols: Int = 20, rows: Int = 5) -> TabDanceTerminalView {
        let options = TerminalOptions(cols: cols, rows: rows)
        return TabDanceTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            options: options
        )
    }

    private func makeWindow(for view: TabDanceTerminalView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: view.getOptimalFrameSize(),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeFirstResponder(view)
        return window
    }

    private func mouseEvent(_ type: NSEvent.EventType, in view: TabDanceTerminalView,
                            col: Int, row: Int, modifiers: NSEvent.ModifierFlags = [],
                            clickCount: Int = 1) throws -> NSEvent {
        let window = try XCTUnwrap(view.window)
        let size = view.getWindowSize()
        let cellWidth = CGFloat(size.ws_xpixel) / window.backingScaleFactor / CGFloat(view.terminal.cols)
        let cellHeight = view.getOptimalFrameSize().height / CGFloat(view.terminal.rows)
        let point = NSPoint(x: (CGFloat(col) + 0.25) * cellWidth,
                            y: view.bounds.height - (CGFloat(row) + 0.5) * cellHeight)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
        ))
    }

    func testRepeatedKeyEventsReachTerminalInput() throws {
        _ = NSApplication.shared
        let view = makeView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeFirstResponder(view)
        defer { window.close() }

        let cases: [(characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, expected: String)] = [
            ("a", 0, [], "a"),
            ("A", 0, [.shift], "A"),
            ("1", 18, [], "1"),
            ("\u{7F}", 51, [], "\u{7F}"),
            (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123, [.function], "\u{1B}[D")
        ]
        for key in cases {
            var input: [UInt8] = []
            view.onUserInput = { input.append(contentsOf: $0) }
            for isRepeat in [false, true, true] {
                let event = try XCTUnwrap(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: key.modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters,
                    isARepeat: isRepeat, keyCode: key.keyCode
                ))
                view.keyDown(with: event)
            }
            XCTAssertEqual(String(decoding: input, as: UTF8.self),
                           String(repeating: key.expected, count: 3), "Key code \(key.keyCode)")
        }
    }

    func testSelectionSnapshotSurvivesPTYRedrawUntilExplicitClear() {
        let view = makeView()
        view.feed(text: "hello")
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 5, row: 0))
        XCTAssertEqual(view.selectedTextSnapshot, "hello")

        view.feed(text: "\r\u{1B}[2K")
        XCTAssertEqual(view.copyText, "hello")
        XCTAssertFalse(String(decoding: view.terminal.getBufferAsData(), as: UTF8.self).contains("hello"))

        view.clearSelection()
        XCTAssertNil(view.copyText)
    }

    func testSingleDragSelectsFromMouseDownInEitherDirection() throws {
        let view = makeView(cols: 80, rows: 12)
        let window = makeWindow(for: view)
        defer { window.close() }
        view.feed(text: "\u{1B}[3;1Hcopy this question")

        for (start, end) in [(5, 9), (9, 5)] {
            view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, col: start, row: 2))
            view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: view, col: end, row: 2))
            view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view, col: end, row: 2))

            XCTAssertEqual(view.copyText, "this")
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "this")
        }
    }

    func testQuestionDragSurvivesPTYRedrawsAndCopiesMultipleLines() throws {
        let question = "The key is valid, but access is denied."
        let link = "https://example.com/model/access"
        for alternate in [false, true] {
            let view = makeView(cols: 80, rows: 12)
            let window = makeWindow(for: view)
            defer { window.close() }
            if alternate { view.feed(text: "\u{1B}[?1049h") }
            let redraw = "\u{1B}[?2026h\u{1B}[3;1H\u{1B}[2K\(question)\r\n\u{1B}[2K\(link)\r\n1. Continue\u{1B}[?2026l"
            view.dataReceived(slice: Array(redraw.utf8)[...])

            view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, col: 0, row: 2))
            view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: view, col: 0, row: 2))
            view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: view, col: 12, row: 2))
            XCTAssertEqual(view.copyText, String(question.prefix(12)))

            // A TUI can repaint the same question between every pair of drag events.
            for end in [24, question.count] {
                view.dataReceived(slice: Array(redraw.utf8)[...])
                XCTAssertTrue(view.selection.active, "PTY output must not interrupt the drag")
                view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: view, col: end, row: 2))
                XCTAssertEqual(view.copyText, String(question.prefix(end)))
            }
            view.dataReceived(slice: Array(redraw.utf8)[...])
            view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: view, col: link.count, row: 3))
            view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view, col: link.count, row: 3))
            let expected = question + "\n" + link
            XCTAssertEqual(view.copyText, expected)
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), expected)

            // Copy still uses the captured text even if the question is erased.
            view.dataReceived(slice: Array("\u{1B}[3;1H\u{1B}[0J".utf8)[...])
            let copyItem = NSMenuItem(title: "Copy", action: #selector(view.copy(_:)), keyEquivalent: "c")
            XCTAssertTrue(view.validateUserInterfaceItem(copyItem))
            XCTAssertTrue(view.tryToPerform(#selector(view.copy(_:)), with: copyItem))
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), expected)
            XCTAssertTrue(view.allowMouseReporting)

            view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, col: 0, row: 5))
            view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view, col: 0, row: 5))
            XCTAssertNil(view.copyText)
            XCTAssertFalse(view.validateUserInterfaceItem(copyItem))
        }
    }

    func testShiftDragSurvivesOutputWhileApplicationMouseReportingStaysEnabled() throws {
        let view = makeView(cols: 80, rows: 12)
        let window = makeWindow(for: view)
        defer { window.close() }
        let redraw = "\u{1B}[3;1Hcopy this question\r\n"
        view.dataReceived(slice: Array(("\u{1B}[?1002h\u{1B}[?1006h" + redraw).utf8)[...])

        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, col: 5, row: 2, modifiers: .shift))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: view, col: 9, row: 2, modifiers: .shift))
        XCTAssertEqual(view.copyText, "this")
        view.dataReceived(slice: Array(redraw.utf8)[...])
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: view, col: 18, row: 2, modifiers: .shift))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view, col: 18, row: 2, modifiers: .shift))
        XCTAssertEqual(view.copyText, "this question")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "this question")
        XCTAssertTrue(view.allowMouseReporting)
        XCTAssertEqual(view.terminal.mouseMode, .buttonEventTracking)

        // Unmodified gestures still belong to an application that requests them.
        view.clearSelection()
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, col: 5, row: 2))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: view, col: 9, row: 2))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view, col: 9, row: 2))
        XCTAssertFalse(view.selection.active)
        XCTAssertNil(view.copyText)

        view.allowMouseReporting = false
        view.dataReceived(slice: Array(redraw.utf8)[...])
        XCTAssertFalse(view.allowMouseReporting)
    }

    func testWordSelectionKeepsItsAnchorAcrossPTYRedraw() throws {
        let view = makeView(cols: 80, rows: 12)
        let window = makeWindow(for: view)
        defer { window.close() }
        let redraw = "\u{1B}[3;1Halpha beta gamma\r\n"
        view.dataReceived(slice: Array(redraw.utf8)[...])

        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, col: 7, row: 2, clickCount: 2))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view, col: 7, row: 2, clickCount: 2))
        XCTAssertEqual(view.copyText, "beta")

        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, col: 7, row: 2, clickCount: 2))
        view.dataReceived(slice: Array(redraw.utf8)[...])
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: view, col: 1, row: 2, clickCount: 2))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view, col: 1, row: 2, clickCount: 2))
        XCTAssertEqual(view.copyText, "alpha beta")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "alpha beta")
    }

    func testPTYScreenSwitchDropsLiveRangeButKeepsCapturedText() {
        let view = makeView()
        view.dataReceived(slice: Array("shell output".utf8)[...])
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 12, row: 0))

        view.dataReceived(slice: Array("\u{1B}[?1049h\u{1B}[Hquestion".utf8)[...])
        XCTAssertFalse(view.selection.active)
        XCTAssertEqual(view.copyText, "shell output")

        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 8, row: 0))
        view.dataReceived(slice: Array("\u{1B}[?1049l".utf8)[...])
        XCTAssertFalse(view.selection.active)
        XCTAssertEqual(view.copyText, "question")
        view.copy(view)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "question")
    }

    func testParserReplyPreservesSelectionAndDoesNotCountAsUserInput() {
        let view = makeView()
        view.feed(text: "hello")
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 5, row: 0))
        var observed: [[UInt8]] = []
        view.onUserInput = { observed.append(Array($0)) }

        view.feed(text: "\u{1B}[6n") // Device status query; parser replies through TerminalDelegate.send.

        XCTAssertEqual(view.copyText, "hello")
        XCTAssertEqual(view.selectedTextSnapshot, "hello")
        XCTAssertTrue(observed.isEmpty)

        let input = Array("x".utf8)
        view.send(source: view, data: input[...])
        XCTAssertNil(view.copyText)
        XCTAssertEqual(observed, [input])
    }

    func testClearToStartDropsPriorOutputAndRetainsPartialCommandWithoutInput() {
        let view = makeView()
        view.feed(text: "old log\r\n$ partial")
        let originalColumn = view.terminal.buffer.x
        var sentInput = 0
        view.onUserInput = { sentInput += $0.count }

        view.clearToStart(nil)

        let output = String(decoding: view.terminal.getBufferAsData(), as: UTF8.self)
        XCTAssertFalse(output.contains("old log"))
        XCTAssertTrue(output.contains("$ partial"))
        XCTAssertEqual(view.terminal.buffer.x, originalColumn)
        XCTAssertEqual(view.terminal.buffer.y, 0)
        XCTAssertEqual(sentInput, 0)
        view.selectAll(nil)
        XCTAssertFalse(view.copyText?.contains("old log") ?? false)
        XCTAssertTrue(view.copyText?.contains("$ partial") ?? false)
    }

    func testClearToStartKeepsWrappedPromptAsOneLogicalLine() {
        let view = makeView(cols: 8, rows: 4)
        let cols = view.terminal.cols
        let wrapped = String(repeating: "p", count: cols + 3)
        view.feed(text: "older\r\n\u{1B}[38;5;196m" + wrapped)
        XCTAssertTrue(view.terminal.getLine(row: 2)?.isWrapped == true)
        view.feed(text: "\u{1B}[2D") // Cursor sits inside an unfinished command.
        let originalColumn = view.terminal.buffer.x

        view.clearToStart(nil)

        let output = String(decoding: view.terminal.getBufferAsData(), as: UTF8.self)
        XCTAssertFalse(output.contains("older"))
        XCTAssertTrue(output.contains(String(repeating: "p", count: cols)))
        XCTAssertTrue(output.contains("ppp"))
        XCTAssertTrue(view.terminal.getLine(row: 1)?.isWrapped == true)
        XCTAssertEqual(view.terminal.getCharData(col: 0, row: 0)?.attribute.fg, .ansi256(code: 196))
        XCTAssertEqual(view.terminal.buffer.y, 1)
        XCTAssertEqual(view.terminal.buffer.x, originalColumn)
    }

    func testAlternateScreenClearDoesNotEraseNormalBuffer() {
        let view = makeView()
        view.feed(text: "normal output")
        view.feed(text: "\u{1B}[?1049h\u{1B}[?2004hALT\r\nactive")
        XCTAssertTrue(view.terminal.isCurrentBufferAlternate)
        XCTAssertTrue(view.terminal.bracketedPasteMode)
        var sentInput = 0
        view.onUserInput = { sentInput += $0.count }

        view.clearToStart(nil)

        XCTAssertTrue(view.terminal.isCurrentBufferAlternate)
        XCTAssertTrue(view.terminal.bracketedPasteMode)
        XCTAssertEqual(sentInput, 0)
        let alternate = String(decoding: view.terminal.getBufferAsData(), as: UTF8.self)
        XCTAssertFalse(alternate.contains("ALT"))
        XCTAssertTrue(alternate.contains("active"))
        view.feed(text: "\u{1B}[?1049l")
        XCTAssertTrue(String(decoding: view.terminal.getBufferAsData(), as: UTF8.self).contains("normal output"))
    }

    func testClearToStartKeepsWrappedContinuationBelowCursor() {
        let view = makeView(cols: 8, rows: 4)
        let cols = view.terminal.cols
        view.feed(text: "older\r\n" + String(repeating: "x", count: cols + 3))
        view.feed(text: "\u{1B}[1A")
        XCTAssertEqual(view.terminal.buffer.y, 1)

        view.clearToStart(nil)

        XCTAssertEqual(view.terminal.buffer.y, 0)
        XCTAssertTrue(view.terminal.getLine(row: 1)?.isWrapped == true)
        XCTAssertEqual(view.terminal.getLine(row: 1)?.translateToString(trimRight: true), "xxx")
    }

    func testClearToStartRemovesScrollbackFromSelectAll() {
        let view = makeView(cols: 20, rows: 3)
        view.feed(text: (0..<12).map { "log\($0)\r\n" }.joined() + "$ ready")
        XCTAssertTrue(String(decoding: view.terminal.getBufferAsData(), as: UTF8.self).contains("log0"))
        view.terminal.buffer.yDisp = 0 // Clear while the viewport is in scrollback.

        view.clearToStart(nil)
        view.selectAll(nil)

        XCTAssertFalse(view.copyText?.contains("log0") ?? false)
        XCTAssertFalse(view.copyText?.contains("log11") ?? false)
        XCTAssertTrue(view.copyText?.contains("$ ready") ?? false)
    }
}
