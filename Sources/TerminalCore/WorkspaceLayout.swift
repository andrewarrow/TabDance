import Foundation

public struct TerminalTab: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var directory: String
    public var title: String

    public init(directory: String, title: String = "Shell") {
        id = UUID()
        self.directory = URL(fileURLWithPath: directory).standardizedFileURL.path
        self.title = title
    }

    public var displayName: String {
        let url = URL(fileURLWithPath: directory).standardizedFileURL
        return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }
}

public struct TerminalWorkspace: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var tabs: [TerminalTab]
    public var selectedTabID: UUID

    public init(directory: String) {
        id = UUID()
        let tab = TerminalTab(directory: directory)
        tabs = [tab]
        selectedTabID = tab.id
    }

    public func displayName(home: String) -> String {
        guard let directory = tabs.first?.directory else { return "Workspace" }
        let path = URL(fileURLWithPath: directory).standardizedFileURL.path
        let home = URL(fileURLWithPath: home).standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return String(path.dropFirst(home.count + 1).split(separator: "/").first ?? "~")
        }
        return tabs[0].displayName
    }
}

/// Stable identities keep selection attached to sessions when rows move.
public struct WorkspaceLayout: Codable, Equatable, Sendable {
    public var workspaces: [TerminalWorkspace]
    public private(set) var activeWorkspaceID: UUID
    private var version = 1

    public init(directory: String) {
        let workspace = TerminalWorkspace(directory: directory)
        workspaces = [workspace]
        activeWorkspaceID = workspace.id
    }

    public var activeWorkspaceIndex: Int {
        workspaces.firstIndex { $0.id == activeWorkspaceID } ?? 0
    }

    public var activeWorkspace: TerminalWorkspace { workspaces[activeWorkspaceIndex] }
    public var selectedTab: TerminalTab {
        activeWorkspace.tabs.first { $0.id == activeWorkspace.selectedTabID } ?? activeWorkspace.tabs[0]
    }

    public mutating func selectWorkspace(at index: Int) {
        guard workspaces.indices.contains(index) else { return }
        activeWorkspaceID = workspaces[index].id
    }

    public mutating func selectTab(_ id: UUID) {
        guard activeWorkspace.tabs.contains(where: { $0.id == id }) else { return }
        workspaces[activeWorkspaceIndex].selectedTabID = id
    }

    @discardableResult
    public mutating func addWorkspace(directory: String) -> TerminalTab {
        let workspace = TerminalWorkspace(directory: directory)
        workspaces.append(workspace)
        activeWorkspaceID = workspace.id
        return workspace.tabs[0]
    }

    @discardableResult
    public mutating func addTab() -> TerminalTab {
        let tab = TerminalTab(directory: selectedTab.directory)
        let index = activeWorkspaceIndex
        workspaces[index].tabs.append(tab)
        workspaces[index].selectedTabID = tab.id
        return tab
    }

    public mutating func cycleTab(by offset: Int) {
        let tabs = activeWorkspace.tabs
        let current = tabs.firstIndex { $0.id == activeWorkspace.selectedTabID } ?? 0
        selectTab(tabs[(current + offset % tabs.count + tabs.count) % tabs.count].id)
    }

    public mutating func cycleWorkspace(by offset: Int) {
        selectWorkspace(at: (activeWorkspaceIndex + offset % workspaces.count + workspaces.count) % workspaces.count)
    }

    /// Returns false for the last tab; the caller closes the window instead.
    @discardableResult
    public mutating func removeTab(_ id: UUID) -> Bool {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.tabs.contains { $0.id == id } }),
              let tabIndex = workspaces[workspaceIndex].tabs.firstIndex(where: { $0.id == id }) else { return false }
        if workspaces.count == 1 && workspaces[0].tabs.count == 1 { return false }
        workspaces[workspaceIndex].tabs.remove(at: tabIndex)
        if workspaces[workspaceIndex].tabs.isEmpty {
            let removed = workspaces.remove(at: workspaceIndex)
            if activeWorkspaceID == removed.id {
                activeWorkspaceID = workspaces[min(workspaceIndex, workspaces.count - 1)].id
            }
        } else if workspaces[workspaceIndex].selectedTabID == id {
            let tabs = workspaces[workspaceIndex].tabs
            workspaces[workspaceIndex].selectedTabID = tabs[min(tabIndex, tabs.count - 1)].id
        }
        return true
    }

    public mutating func moveWorkspace(from: Int, to: Int) {
        guard workspaces.indices.contains(from), workspaces.indices.contains(to), from != to else { return }
        workspaces.insert(workspaces.remove(at: from), at: to)
    }

    /// Moves the workspace with this identity to an insertion gap in the current order.
    /// The gap is measured before removal, so dropping after the source is adjusted once.
    @discardableResult
    public mutating func moveWorkspace(_ id: UUID, toInsertionIndex insertionIndex: Int) -> Bool {
        guard let from = workspaces.firstIndex(where: { $0.id == id }),
              (0...workspaces.count).contains(insertionIndex) else { return false }
        let to = insertionIndex > from ? insertionIndex - 1 : insertionIndex
        guard to != from else { return true }
        workspaces.insert(workspaces.remove(at: from), at: to)
        return true
    }

    public mutating func moveTab(from: Int, to: Int) {
        let index = activeWorkspaceIndex
        guard workspaces[index].tabs.indices.contains(from), workspaces[index].tabs.indices.contains(to), from != to else { return }
        workspaces[index].tabs.insert(workspaces[index].tabs.remove(at: from), at: to)
    }

    /// Moves a tab within its workspace to an insertion gap in the current order.
    @discardableResult
    public mutating func moveTab(_ id: UUID, in workspaceID: UUID, toInsertionIndex insertionIndex: Int) -> Bool {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let from = workspaces[workspaceIndex].tabs.firstIndex(where: { $0.id == id }) else { return false }
        let count = workspaces[workspaceIndex].tabs.count
        guard (0...count).contains(insertionIndex) else { return false }
        let to = insertionIndex > from ? insertionIndex - 1 : insertionIndex
        guard to != from else { return true }
        workspaces[workspaceIndex].tabs.insert(workspaces[workspaceIndex].tabs.remove(at: from), at: to)
        return true
    }

    public mutating func updateTab(_ id: UUID, directory: String? = nil, title: String? = nil) {
        for workspaceIndex in workspaces.indices {
            guard let index = workspaces[workspaceIndex].tabs.firstIndex(where: { $0.id == id }) else { continue }
            if let directory { workspaces[workspaceIndex].tabs[index].directory = URL(fileURLWithPath: directory).standardizedFileURL.path }
            if let title { workspaces[workspaceIndex].tabs[index].title = title }
            return
        }
    }

    public static func restore(from data: Data) -> WorkspaceLayout? {
        guard let layout = try? JSONDecoder().decode(Self.self, from: data),
              layout.version == 1, !layout.workspaces.isEmpty,
              layout.workspaces.contains(where: { $0.id == layout.activeWorkspaceID }),
              layout.workspaces.allSatisfy({ workspace in
                  !workspace.tabs.isEmpty && workspace.tabs.contains { $0.id == workspace.selectedTabID }
                      && workspace.tabs.allSatisfy { $0.directory.hasPrefix("/") }
              }) else { return nil }
        let tabs = layout.workspaces.flatMap(\.tabs)
        guard tabs.count <= 128, Set(tabs.map(\.id)).count == tabs.count,
              Set(layout.workspaces.map(\.id)).count == layout.workspaces.count else { return nil }
        return layout
    }
}
