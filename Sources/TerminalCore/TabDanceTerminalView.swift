import AppKit
import SwiftTerm

/// Local terminal behavior that belongs to the view, rather than the child process.
public final class TabDanceTerminalView: LocalProcessTerminalView {
    /// Called only for bytes the user sends to the child, not terminal replies or PTY output.
    public var onUserInput: ((ArraySlice<UInt8>) -> Void)?

    /// Text captured when the user made a selection. PTY redraws may invalidate the
    /// live cells before Copy is invoked, but do not change what the user selected.
    public private(set) var selectedTextSnapshot: String?

    private var selectionPress: NSEvent?
    private var isReceivingOutput = false

    public override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    public override init(frame: CGRect, font: NSFont? = nil, options: TerminalOptions) {
        super.init(frame: frame, font: font, options: options)
        registerForDraggedTypes([.fileURL])
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    public var copyText: String? {
        selectedTextSnapshot ?? getSelection()
    }

    public override func selectionChanged(source: Terminal) {
        if selection.active && !isReceivingOutput {
            selectedTextSnapshot = selection.getSelectedText()
            if let selectedTextSnapshot, !selectedTextSnapshot.isEmpty {
                copy(self)
            }
        }
        super.selectionChanged(source: source)
    }

    /// An explicit user selection reset also discards the saved text.
    public func clearSelection() {
        selectionPress = nil
        selectedTextSnapshot = nil
        selection.selectNone()
    }

    public override func mouseDown(with event: NSEvent) {
        selectionPress = nil
        selectedTextSnapshot = nil
        super.mouseDown(with: event)
        if !selection.active && selectsLocally(with: event) {
            selectionPress = event
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        if let press = selectionPress {
            selectionPress = nil
            if !selection.active && selectsLocally(with: press) && selectsLocally(with: event) {
                // SwiftTerm otherwise anchors at the first drag event, losing the
                // text between the press and that event (or the entire quick drag).
                super.mouseDragged(with: press)
            }
        }
        super.mouseDragged(with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        selectionPress = nil
        super.mouseUp(with: event)
    }

    private func selectsLocally(with event: NSEvent) -> Bool {
        !allowMouseReporting || terminal.mouseMode == .off ||
            (event.modifierFlags.contains(.shift) && !terminal.mouseShiftCapture)
    }

    public override func dataReceived(slice: ArraySlice<UInt8>) {
        // SwiftTerm 1.19 clears selection on every feed and linefeed when mouse
        // reporting is allowed, even if the child has not requested mouse input.
        // Suppress that output-side reset without changing mouse-event routing.
        let previousMouseReporting = allowMouseReporting
        let wasReceivingOutput = isReceivingOutput
        allowMouseReporting = false
        isReceivingOutput = true
        defer {
            allowMouseReporting = previousMouseReporting
            isReceivingOutput = wasReceivingOutput
        }
        super.dataReceived(slice: slice)
    }

    public override func bufferActivated(source: Terminal) {
        // A live range belongs to one screen. Keep its copy snapshot, but do not
        // highlight or extend that range into the other screen's unrelated cells.
        selectionPress = nil
        selection.selectNone()
        super.bufferActivated(source: source)
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAcceptFileDrop(sender) ? .copy : []
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAcceptFileDrop(sender) ? .copy : []
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canAcceptFileDrop(sender)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard sender.draggingSourceOperationMask.contains(.copy), process.running,
              let paths = shellEscapedPaths(from: sender), let window else { return false }
        guard window.makeFirstResponder(self) else { return false }

        let text = paths.map { "\($0) " }.joined()
        var bytes = Array(text.utf8)
        if terminal.bracketedPasteMode {
            bytes.insert(contentsOf: [27, 91, 50, 48, 48, 126], at: 0)
            bytes.append(contentsOf: [27, 91, 50, 48, 49, 126])
        }
        send(data: bytes[...])
        return true
    }

    public func canAcceptFileDrop(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingSourceOperationMask.contains(.copy) && process.running && shellEscapedPaths(from: sender) != nil
    }

    private func shellEscapedPaths(from sender: NSDraggingInfo) -> [String]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else { return nil }

        guard urls.allSatisfy({ url in
            let host = url.host?.lowercased()
            return host == nil || host == "" || host == "localhost" || host == ProcessInfo.processInfo.hostName.lowercased()
        }) else { return nil }
        let paths = urls.map(\.path)
        guard paths.allSatisfy({ path in
            !path.isEmpty && path.hasPrefix("/") && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }) else { return nil }
        return paths.map(Self.shellEscape)
    }

    private static func shellEscape(_ path: String) -> String {
        let escapedCharacters = CharacterSet(charactersIn: "\\ ()[]{}<>\"'`!#$&;|*?~^=")
        return path.unicodeScalars.reduce(into: "") { result, scalar in
            if escapedCharacters.contains(scalar) { result.append("\\") }
            result.append(String(scalar))
        }
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
