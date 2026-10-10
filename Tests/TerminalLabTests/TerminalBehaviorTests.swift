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
