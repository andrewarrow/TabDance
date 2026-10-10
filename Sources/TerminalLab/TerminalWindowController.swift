import AppKit
import TerminalCore

@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let command: LaunchCommand
    private let stateURL: URL?
    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private var layout: WorkspaceLayout
    private var sessions: [UUID: TerminalSession] = [:]
    private let activity = CodexActivityMonitor()
    private let content = WindowContentView()
    private let sidebar = NSView()
    private let table = NSTableView()
    private let terminalHost = NSView()
    private let tabScroll = TabBarScrollView(frame: .zero)
    private let tabStack = NSStackView()
    private let workspaceButton = ActionButton(symbol: "sidebar.left", label: "Workspaces")
    private var sidebarWidth: NSLayoutConstraint!
    private var activityTimer: Timer?
    private var polling = false
    private var saveTask: Task<Void, Never>?
    private var closing = false
    private var refreshing = false
    private var wantsSidebar = true
    private let workspaceDragType = NSPasteboard.PasteboardType("dev.tabdance.workspace")

    init(command: LaunchCommand, stateURL: URL?) {
        self.command = command
        self.stateURL = stateURL
        if let stateURL, let data = try? Data(contentsOf: stateURL), let restored = WorkspaceLayout.restore(from: data) {
            layout = restored
        } else {
            layout = WorkspaceLayout(directory: FileManager.default.homeDirectoryForCurrentUser.path)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "TabDance"
        window.minSize = NSSize(width: 360, height: 240)
        window.tabbingMode = .disallowed
        window.center()
        window.delegate = self
        window.contentView = content
        buildViews()
        window.makeKeyAndOrderFront(nil)
        content.layoutSubtreeIfNeeded()
        let restoredTabs = layout.workspaces.flatMap(\.tabs)
        for tab in restoredTabs { addSession(tab) }
        refresh(focusTerminal: true)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.pollActivity() }
        }
        RunLoop.main.add(timer, forMode: .common)
        activityTimer = timer
    }

    required init?(coder: NSCoder) { nil }
    var isRunning: Bool { sessions.values.contains(where: \.isRunning) }

    private func buildViews() {
        let workspaceScroll = NSScrollView()
        workspaceScroll.hasVerticalScroller = true
        workspaceScroll.drawsBackground = false
        table.headerView = nil
        table.rowHeight = 44
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.style = .sourceList
        table.backgroundColor = .windowBackgroundColor
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Workspaces")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workspace"))
        column.width = 160
        table.addTableColumn(column)
        table.registerForDraggedTypes([workspaceDragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        workspaceScroll.documentView = table
        let heading = NSTextField(labelWithString: "Workspaces")
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        let addWorkspace = ActionButton(symbol: "plus", label: "New workspace (⇧⌘N)")
        addWorkspace.onPress = { [weak self] in self?.newWorkspace(nil) }
        let divider = NSBox()
        divider.boxType = .separator
        let tabBar = NSView()
        let tabDivider = NSBox()
        tabDivider.boxType = .separator
        let addTab = ActionButton(symbol: "plus", label: "New tab (⌘T)")
        addTab.onPress = { [weak self] in self?.newTab(nil) }
        workspaceButton.onPress = { [weak self] in self?.showWorkspaceMenu() }
        tabScroll.drawsBackground = false
        tabScroll.hasHorizontalScroller = false
        tabScroll.canMoveTab = { [weak self] tabID, workspaceID in
            guard let self else { return false }
            return self.layout.activeWorkspaceID == workspaceID
                && self.layout.activeWorkspace.tabs.contains { $0.id == tabID }
        }
        tabScroll.moveTab = { [weak self] tabID, workspaceID, insertionIndex in
            guard let self, self.layout.activeWorkspaceID == workspaceID,
                  self.layout.moveTab(tabID, in: workspaceID, toInsertionIndex: insertionIndex) else { return false }
            self.refresh(focusTerminal: true)
            return true
        }
        tabStack.orientation = .horizontal
        tabStack.spacing = 4
        tabStack.alignment = .centerY
        tabStack.distribution = .fill
        tabScroll.documentView = tabStack
        for view in [sidebar, divider, tabBar, tabDivider, terminalHost] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        for view in [heading, addWorkspace, workspaceScroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(view)
        }
        for view in [workspaceButton, tabScroll, addTab] {
            view.translatesAutoresizingMaskIntoConstraints = false
            tabBar.addSubview(view)
        }
        sidebarWidth = divider.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 160)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 160), sidebarWidth,
            heading.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            heading.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 12),
            addWorkspace.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            addWorkspace.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 4),
            addWorkspace.widthAnchor.constraint(equalToConstant: 28),
            addWorkspace.heightAnchor.constraint(equalToConstant: 32),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: addWorkspace.leadingAnchor),
            workspaceScroll.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 40),
            workspaceScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 4),
            workspaceScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -4),
            workspaceScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -8),
            divider.topAnchor.constraint(equalTo: content.topAnchor),
            divider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            tabBar.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: content.topAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 40),
            workspaceButton.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor, constant: 4),
            workspaceButton.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            workspaceButton.widthAnchor.constraint(equalToConstant: 32),
            workspaceButton.heightAnchor.constraint(equalToConstant: 32),
            tabScroll.leadingAnchor.constraint(equalTo: workspaceButton.trailingAnchor, constant: 4),
            tabScroll.trailingAnchor.constraint(equalTo: addTab.leadingAnchor, constant: -4),
            tabScroll.topAnchor.constraint(equalTo: tabBar.topAnchor, constant: 4),
            tabScroll.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: -4),
            addTab.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor, constant: -4),
            addTab.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            addTab.widthAnchor.constraint(equalToConstant: 32),
            addTab.heightAnchor.constraint(equalToConstant: 32),
            tabDivider.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor),
            tabDivider.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            tabDivider.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            tabDivider.heightAnchor.constraint(equalToConstant: 1),
            terminalHost.topAnchor.constraint(equalTo: tabDivider.bottomAnchor),
            terminalHost.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor),
            terminalHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            terminalHost.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        content.onResize = { [weak self] in self?.updateSidebarVisibility() }
    }

    private func addSession(_ tab: TerminalTab) {
        let session = TerminalSession(tab: tab, frame: terminalHost.bounds, activity: activity)
        session.terminal.autoresizingMask = [.width, .height]
        session.terminal.isHidden = true
        terminalHost.addSubview(session.terminal)
        sessions[tab.id] = session
        session.onChange = { [weak self] directory, title in
            guard let self, !self.closing else { return }
            self.layout.updateTab(tab.id, directory: directory, title: title)
            self.refresh(focusTerminal: false)
        }
        session.start(command: command, directory: tab.directory)
    }

    private func refresh(focusTerminal: Bool) {
        guard !closing else { return }
        refreshing = true
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: layout.activeWorkspaceIndex), byExtendingSelection: false)
        table.scrollRowToVisible(layout.activeWorkspaceIndex)
        let tabs = layout.activeWorkspace.tabs
        let tabViews = tabStack.arrangedSubviews.compactMap { $0 as? TerminalTabView }
        // Preserve in-progress clicks and drags while terminal metadata changes.
        let tabsChanged = tabViews.map(\.tabID) != tabs.map(\.id)
        if tabsChanged {
            for view in tabStack.arrangedSubviews {
                tabStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
        }
        for (index, tab) in tabs.enumerated() {
            let name = tab.displayName + (sessions[tab.id]?.isRunning == true ? "" : " — Exited")
            let detail = "\(tab.directory)\n\(tab.title)"
            let active = tab.id == layout.selectedTab.id
            if !tabsChanged {
                tabViews[index].configure(name: name, detail: detail, active: active)
                tabViews[index].terminal = sessions[tab.id]?.terminal
                continue
            }
            let view = TerminalTabView(tabID: tab.id, workspaceID: layout.activeWorkspaceID, name: name, detail: detail, active: active,
                                       onSelect: { [weak self] in self?.selectTab(tab.id) },
                                       onClose: { [weak self] in self?.closeTab(tab.id) })
            view.tabBar = tabScroll
            view.terminal = sessions[tab.id]?.terminal
            tabStack.addArrangedSubview(view)
        }
        tabStack.frame = NSRect(origin: .zero, size: NSSize(width: CGFloat(layout.activeWorkspace.tabs.count) * 156 - 4, height: 32))
        tabStack.layoutSubtreeIfNeeded()
        if focusTerminal || tabsChanged, let index = tabs.firstIndex(where: { $0.id == layout.selectedTab.id }) {
            tabStack.scrollToVisible(NSRect(x: CGFloat(index) * 156, y: 0, width: 152, height: 32))
        }
        for (id, session) in sessions { session.terminal.isHidden = id != layout.selectedTab.id }
        let tab = layout.selectedTab
        window?.title = "\(tab.displayName) — TabDance" + (sessions[tab.id]?.isRunning == true ? "" : " — Exited")
        window?.representedURL = URL(fileURLWithPath: tab.directory)
        refreshing = false
        if focusTerminal, let terminal = sessions[tab.id]?.terminal { window?.makeFirstResponder(terminal) }
        scheduleSave()
    }

    private func updateSidebarVisibility() {
        let visible = wantsSidebar && content.bounds.width >= 600
        let width: CGFloat = visible ? 160 : 0
        if sidebarWidth.constant != width { sidebarWidth.constant = width }
        // Keep the sidebar's internal layout valid when it is collapsed.
        sidebar.isHidden = !visible
    }

    @objc func toggleSidebar(_ sender: Any?) {
        if content.bounds.width < 600 { showWorkspaceMenu(); return }
        wantsSidebar.toggle()
        updateSidebarVisibility()
    }

    private func showWorkspaceMenu() {
        let menu = NSMenu()
        for (index, workspace) in layout.workspaces.enumerated() {
            let item = menu.addItem(withTitle: workspace.displayName(home: home), action: #selector(selectWorkspaceMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == layout.activeWorkspaceIndex ? .on : .off
        }
        menu.addItem(.separator())
        let add = menu.addItem(withTitle: "New Workspace", action: #selector(newWorkspace(_:)), keyEquivalent: "")
        add.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: workspaceButton.bounds.height), in: workspaceButton)
    }

    @objc private func selectWorkspaceMenu(_ sender: NSMenuItem) {
        layout.selectWorkspace(at: sender.tag)
        refresh(focusTerminal: true)
    }

    private func selectTab(_ id: UUID) {
        layout.selectTab(id)
        refresh(focusTerminal: true)
    }

    @objc func newTab(_ sender: Any?) {
        synchronizeSelectedDirectory()
        let tab = layout.addTab()
        addSession(tab)
        refresh(focusTerminal: true)
    }

    @objc func newWorkspace(_ sender: Any?) {
        synchronizeSelectedDirectory()
        let tab = layout.addWorkspace(directory: layout.selectedTab.directory)
        addSession(tab)
        refresh(focusTerminal: true)
    }

    private func synchronizeSelectedDirectory() {
        guard let session = sessions[layout.selectedTab.id], session.isRunning,
              let directory = activity.currentDirectory(shellPID: session.terminal.process.shellPid) else { return }
        layout.updateTab(session.id, directory: directory)
    }

    @objc func nextTab(_ sender: Any?) { layout.cycleTab(by: 1); refresh(focusTerminal: true) }
    @objc func previousTab(_ sender: Any?) { layout.cycleTab(by: -1); refresh(focusTerminal: true) }
    @objc func nextWorkspace(_ sender: Any?) { layout.cycleWorkspace(by: 1); refresh(focusTerminal: true) }
    @objc func previousWorkspace(_ sender: Any?) { layout.cycleWorkspace(by: -1); refresh(focusTerminal: true) }
    @objc func selectTabNumber(_ sender: NSMenuItem) {
        let tabs = layout.activeWorkspace.tabs
        let index = sender.tag == 9 ? tabs.count - 1 : sender.tag - 1
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index].id)
    }
    @objc func moveTabLeft(_ sender: Any?) { moveTab(by: -1) }
    @objc func moveTabRight(_ sender: Any?) { moveTab(by: 1) }
    private func moveTab(by offset: Int) {
        guard let index = layout.activeWorkspace.tabs.firstIndex(where: { $0.id == layout.selectedTab.id }) else { return }
        layout.moveTab(from: index, to: index + offset)
        refresh(focusTerminal: true)
    }
    @objc func closeSelectedTab(_ sender: Any?) { closeTab(layout.selectedTab.id) }

    private func closeTab(_ id: UUID) {
        if layout.workspaces.count == 1 && layout.activeWorkspace.tabs.count == 1 {
            window?.close()
            return
        }
        guard layout.removeTab(id) else { return }
        if let session = sessions.removeValue(forKey: id) {
            session.stop()
            session.terminal.removeFromSuperview()
        }
        refresh(focusTerminal: true)
    }

    private func confirmClose(message: String, detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: button).hasDestructiveAction = true
        alert.alertStyle = .warning
        return alert.runModal() == .alertSecondButtonReturn
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !isRunning || closing || confirmClose(message: "Close this window?", detail: "Running shells and commands in every workspace in this window will end.", button: "Close Window")
    }

    func windowWillClose(_ notification: Notification) {
        saveNow()
        closing = true
        stopSessions()
        (NSApp.delegate as? AppDelegate)?.remove(self)
    }

    func stopSessions() {
        activityTimer?.invalidate()
        activityTimer = nil
        saveTask?.cancel()
        sessions.values.forEach { $0.stop() }
    }

    private func pollActivity() async {
        guard !polling, !closing else { return }
        polling = true
        var directoryChanged = false
        for session in Array(sessions.values) {
            guard session.isRunning else { continue }
            let busy = await session.activity.activity(shellPID: session.terminal.process.shellPid)
            guard !closing else { break }
            session.isBusy = busy && session.isRunning
            if session.isRunning, let directory = activity.currentDirectory(shellPID: session.terminal.process.shellPid),
               layout.workspaces.flatMap(\.tabs).first(where: { $0.id == session.id })?.directory != directory {
                layout.updateTab(session.id, directory: directory)
                directoryChanged = true
            }
        }
        polling = false
        if directoryChanged { refresh(focusTerminal: false) }
        for row in layout.workspaces.indices {
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? WorkspaceCell { configure(cell, at: row) }
        }
    }

    private func scheduleSave() {
        guard stateURL != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard let stateURL, let data = try? JSONEncoder().encode(layout) else { return }
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            NSLog("Could not save TabDance workspace layout: %@", error.localizedDescription)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { layout.workspaces.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("WorkspaceCell"), owner: self) as? WorkspaceCell) ?? WorkspaceCell(frame: .zero)
        cell.identifier = NSUserInterfaceItemIdentifier("WorkspaceCell")
        configure(cell, at: row)
        return cell
    }
    private func configure(_ cell: WorkspaceCell, at row: Int) {
        let workspace = layout.workspaces[row]
        cell.configure(name: workspace.displayName(home: home), count: workspace.tabs.count,
                       active: row == layout.activeWorkspaceIndex, busy: workspace.tabs.contains { sessions[$0.id]?.isBusy == true })
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshing, table.selectedRow >= 0 else { return }
        layout.selectWorkspace(at: table.selectedRow)
        refresh(focusTerminal: true)
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(layout.workspaces[row].id.uuidString, forType: workspaceDragType)
        return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard tableView === table, (info.draggingSource as? NSTableView) === table,
              info.draggingSourceOperationMask.contains(.move),
              let value = info.draggingPasteboard.string(forType: workspaceDragType),
              layout.workspaces.contains(where: { $0.id.uuidString == value }),
              (0...layout.workspaces.count).contains(row) else { return [] }
        table.setDropRow(row, dropOperation: .above)
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard tableView === table, (info.draggingSource as? NSTableView) === table,
              info.draggingSourceOperationMask.contains(.move),
              let value = info.draggingPasteboard.string(forType: workspaceDragType),
              let id = layout.workspaces.first(where: { $0.id.uuidString == value })?.id,
              (0...layout.workspaces.count).contains(row), dropOperation == .above,
              layout.moveWorkspace(id, toInsertionIndex: row) else { return false }
        refresh(focusTerminal: true)
        return true
    }
}
