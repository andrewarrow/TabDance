import AppKit

@MainActor
final class ActionButton: NSButton {
    var onPress: (() -> Void)?

    init(title: String = "", symbol: String? = nil, label: String) {
        super.init(frame: .zero)
        self.title = title
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) }
        toolTip = label
        setAccessibilityLabel(label)
        bezelStyle = .recessed
        isBordered = false
        target = self
        action = #selector(press)
    }

    required init?(coder: NSCoder) { nil }
    @objc private func press() { onPress?() }
}

@MainActor
final class WorkspaceCell: NSTableCellView {
    let nameLabel = NSTextField(labelWithString: "")
    let countLabel = NSTextField(labelWithString: "")
    let spinner = NSProgressIndicator()

    override init(frame: NSRect) {
        super.init(frame: frame)
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for view in [nameLabel, countLabel, spinner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            countLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            countLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            countLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor)
        ])
        textField = nameLabel
    }

    required init?(coder: NSCoder) { nil }

    func configure(name: String, count: Int, active: Bool, busy: Bool) {
        nameLabel.stringValue = name
        nameLabel.font = .systemFont(ofSize: 13, weight: active ? .semibold : .regular)
        countLabel.stringValue = "\(count) \(count == 1 ? "tab" : "tabs")"
        toolTip = name
        setAccessibilityLabel("\(name), \(countLabel.stringValue)\(busy ? ", Codex working" : "")")
        if busy {
            spinner.isHidden = false
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                spinner.stopAnimation(nil)
                spinner.isDisplayedWhenStopped = true
            } else {
                spinner.isDisplayedWhenStopped = false
                spinner.startAnimation(nil)
            }
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
    }
}

@MainActor
final class TerminalTabView: NSView, NSDraggingSource {
    let selectButton: ActionButton
    let closeButton: ActionButton
    let tabID: UUID
    let workspaceID: UUID
    weak var tabBar: TabBarScrollView?
    private let dragType = NSPasteboard.PasteboardType("dev.tabdance.tab")
    private var pressLocation: NSPoint?
    private var pressEvent: NSEvent?
    private var dragging = false

    init(tabID: UUID, workspaceID: UUID, name: String, detail: String, active: Bool, onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.tabID = tabID
        self.workspaceID = workspaceID
        selectButton = ActionButton(title: name, label: detail)
        closeButton = ActionButton(symbol: "xmark", label: "Close \(name)")
        super.init(frame: NSRect(x: 0, y: 0, width: 152, height: 32))
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = (active ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18) : .clear).cgColor
        selectButton.font = .systemFont(ofSize: 12, weight: active ? .semibold : .regular)
        selectButton.alignment = .left
        selectButton.lineBreakMode = .byTruncatingTail
        selectButton.onPress = onSelect
        closeButton.onPress = onClose
        for button in [selectButton, closeButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 152),
            heightAnchor.constraint(equalToConstant: 32),
            selectButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            selectButton.topAnchor.constraint(equalTo: topAnchor),
            selectButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            selectButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard let hit else { return nil }
        return hit === selectButton ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        pressLocation = convert(event.locationInWindow, from: nil)
        pressEvent = event
        dragging = false
        selectButton.highlight(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressLocation, !dragging else { return }
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - pressLocation.x, current.y - pressLocation.y) >= 4 else { return }
        guard let tabBar, let pressEvent else { return }
        dragging = true
        self.pressLocation = nil
        self.pressEvent = nil
        selectButton.highlight(false)
        let item = NSPasteboardItem()
        item.setString(tabID.uuidString, forType: dragType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size)
        if let bitmap = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: bitmap)
            image.addRepresentation(bitmap)
        }
        draggingItem.setDraggingFrame(bounds, contents: image)
        tabBar.retainDragSource(self)
        let session = beginDraggingSession(with: [draggingItem], event: pressEvent, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressLocation = nil; pressEvent = nil; dragging = false; selectButton.highlight(false) }
        guard !dragging, pressLocation != nil else { return }
        let released = convert(event.locationInWindow, from: nil)
        guard bounds.contains(released), !closeButton.frame.contains(released) else { return }
        selectButton.performClick(nil)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        tabBar?.finishDrag(source: self)
    }
}

@MainActor
final class TabBarScrollView: NSScrollView {
    let tabDragType = NSPasteboard.PasteboardType("dev.tabdance.tab")
    var canMoveTab: ((UUID, UUID) -> Bool)?
    var moveTab: ((UUID, UUID, Int) -> Bool)?
    private let insertionMarker = NSView(frame: .zero)
    private var activeDragSource: TerminalTabView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([tabDragType])
        insertionMarker.wantsLayer = true
        insertionMarker.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        insertionMarker.isHidden = true
        contentView.addSubview(insertionMarker, positioned: .above, relativeTo: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard validSource(sender) != nil else { clearMarker(); return [] }
        autoScroll(near: sender.draggingLocation)
        updateInsertion(at: sender.draggingLocation)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { clearMarker() }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { validSource(sender) != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let source = validSource(sender) else { clearMarker(); return false }
        let index = insertionIndex(at: sender.draggingLocation)
        clearMarker()
        return moveTab?(source.tabID, source.workspaceID, index) == true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { clearMarker() }

    override func draggingEnded(_ sender: NSDraggingInfo) { clearMarker() }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    func retainDragSource(_ source: TerminalTabView) {
        activeDragSource = source
    }

    func finishDrag(source: TerminalTabView) {
        if activeDragSource === source { activeDragSource = nil }
        clearMarker()
    }

    private func validSource(_ info: NSDraggingInfo) -> TerminalTabView? {
        guard info.draggingSourceOperationMask.contains(.move),
              let source = info.draggingSource as? TerminalTabView,
              source.tabBar === self,
              info.draggingPasteboard.string(forType: tabDragType) == source.tabID.uuidString,
              canMoveTab?(source.tabID, source.workspaceID) == true else { return nil }
        return source
    }

    private func insertionIndex(at windowPoint: NSPoint) -> Int {
        let document = documentView ?? contentView
        let point = document.convert(convert(windowPoint, from: nil), from: self)
        let views = (document as? NSStackView)?.arrangedSubviews.compactMap { $0 as? TerminalTabView } ?? []
        var index = 0
        for view in views {
            if point.x < view.frame.midX { break }
            index += 1
        }
        return index
    }

    private func updateInsertion(at point: NSPoint) {
        let index = insertionIndex(at: point)
        let views = (documentView as? NSStackView)?.arrangedSubviews.compactMap { $0 as? TerminalTabView } ?? []
        let document = documentView ?? contentView
        let x: CGFloat
        if index < views.count {
            x = views[index].frame.minX - 3
        } else if let last = views.last {
            x = last.frame.maxX + 1
        } else {
            x = 1
        }
        let contentX = document.convert(NSPoint(x: x, y: 0), to: contentView).x
        let visibleMin = contentView.bounds.minX
        let visibleMax = contentView.bounds.maxX
        let clampedX = min(max(contentX, visibleMin), max(visibleMin, visibleMax - 2))
        insertionMarker.frame = NSRect(x: clampedX, y: 5, width: 2, height: max(1, contentView.bounds.height - 10))
        insertionMarker.isHidden = false
    }

    private func autoScroll(near windowPoint: NSPoint) {
        let point = convert(windowPoint, from: nil)
        let edge: CGFloat = 24
        let amount: CGFloat = 12
        let visible = contentView.bounds
        var origin = visible.origin
        if point.x < edge { origin.x -= amount }
        else if point.x > bounds.width - edge { origin.x += amount }
        let maxX = max(0, (documentView?.bounds.width ?? visible.width) - visible.width)
        origin.x = min(max(origin.x, 0), maxX)
        guard origin.x != visible.origin.x else { return }
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    private func clearMarker() {
        insertionMarker.isHidden = true
    }
}

@MainActor
final class WindowContentView: NSView {
    var onResize: (() -> Void)?
    override func layout() {
        onResize?()
        super.layout()
    }
}
