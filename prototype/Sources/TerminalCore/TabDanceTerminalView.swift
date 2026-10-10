import AppKit
import SwiftTerm

/// Local terminal behavior that belongs to the view, rather than the child process.
public final class TabDanceTerminalView: LocalProcessTerminalView {
    /// Called only for bytes the user sends to the child, not terminal replies or PTY output.
    public var onUserInput: ((ArraySlice<UInt8>) -> Void)?

    /// Text captured when the user made a selection. PTY redraws may invalidate the
    /// live cells before Copy is invoked, but do not change what the user selected.
    public private(set) var selectedTextSnapshot: String?

    public var copyText: String? {
        selectedTextSnapshot ?? getSelection()
    }

    public override func selectionChanged(source: Terminal) {
        if selection.active {
            selectedTextSnapshot = selection.getSelectedText()
        }
        super.selectionChanged(source: source)
    }

    /// An explicit user selection reset also discards the saved text.
    public func clearSelection() {
        selectedTextSnapshot = nil
        selection.selectNone()
    }

    public override func mouseDown(with event: NSEvent) {
        selectedTextSnapshot = nil
        super.mouseDown(with: event)
    }

    public override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        clearSelection()
        onUserInput?(data)
        super.send(source: source, data: data)
    }

    public override func send(source: Terminal, data: ArraySlice<UInt8>) {
        // Parser replies share SwiftTerm's terminalDelegate forwarding path
        // with user input. Send them to the PTY without changing UI state.
        process.send(data: data)
    }

    public override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return copyText != nil
        }
        if item.action == #selector(clearToStart(_:)) {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    @objc public override func copy(_ sender: Any) {
        guard let text = copyText else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Clears prior screen content and scrollback while retaining the logical
    /// line containing the cursor, including wrapped prompt and command cells.
    /// This operates locally: it does not send Control-L to the shell or app.
    @objc public func clearToStart(_ sender: Any?) {
        clearSelection()

        let buffer = terminal.buffer
        let rows = terminal.rows
        guard rows > 0 else { return }

        // getLine is viewport-relative. Move the viewport to the active screen
        // before inspecting the cursor's line, even if the user scrolled back.
        let firstAbsoluteRow = buffer.totalLinesTrimmed
        var upper = max(1, rows)
        while terminal.getScrollInvariantLine(row: firstAbsoluteRow + upper) != nil {
            upper *= 2
        }
        var lower = upper / 2
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if terminal.getScrollInvariantLine(row: firstAbsoluteRow + middle) == nil {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        buffer.yDisp = max(0, lower - rows)

        let oldCursorRow = min(buffer.y, rows - 1)
        let oldCursorColumn = buffer.x
        var startRow = oldCursorRow
        while startRow > 0, terminal.getLine(row: startRow)?.isWrapped == true {
            startRow -= 1
        }
        var endRow = oldCursorRow
        while endRow + 1 < rows, terminal.getLine(row: endRow + 1)?.isWrapped == true {
            endRow += 1
        }

        let oldScrollTop = buffer.scrollTop
        let oldScrollBottom = buffer.scrollBottom
        buffer.scrollTop = 0
        buffer.scrollBottom = rows - 1

        // SU shifts the retained line and its metadata to the top. Unlike a
        // buffer reset, it preserves attributes, hyperlinks and terminal modes.
        if startRow > 0 {
            terminal.feed(text: "\u{1B}[\(startRow)S")
        }
        let retainedCursorRow = oldCursorRow - startRow
        let retainedEndRow = endRow - startRow
        if retainedEndRow + 1 < rows {
            buffer.x = 0
            buffer.y = retainedEndRow + 1
            terminal.feed(text: "\u{1B}[0J")
        }
        terminal.feed(text: "\u{1B}[3J")
        buffer.x = oldCursorColumn
        buffer.y = retainedCursorRow
        buffer.scrollTop = oldScrollTop
        buffer.scrollBottom = oldScrollBottom
        buffer.yDisp = 0
        terminal.updateFullScreen()
        // Let SwiftTerm update the caret and scroll controls for the new row.
        feed(text: "")
        needsDisplay = true
    }
}
