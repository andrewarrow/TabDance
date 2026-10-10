import XCTest
@testable import TerminalCore

final class WorkspaceTests: XCTestCase {
    func testWorkspacesRememberTheirOwnSelectedTabAndDirectory() {
        var layout = WorkspaceLayout(directory: "/Users/test/os/TabDance")
        let first = layout.selectedTab.id
        let second = layout.addTab().id
        layout.updateTab(second, directory: "/tmp/project")
        XCTAssertEqual(layout.addTab().directory, "/tmp/project")
        layout.selectTab(first)
        let other = layout.addWorkspace(directory: "/Users/test/rio").id
        layout.selectWorkspace(at: 0)
        XCTAssertEqual(layout.selectedTab.id, first)
        layout.cycleTab(by: -1)
        XCTAssertEqual(layout.selectedTab.directory, "/tmp/project")
        layout.cycleWorkspace(by: 1)
        XCTAssertEqual(layout.selectedTab.id, other)
    }

    func testRemovingSelectedTabsAndEmptyWorkspacesChoosesANeighbor() {
        var layout = WorkspaceLayout(directory: "/tmp/one")
        let first = layout.selectedTab.id
        let second = layout.addTab().id
        let third = layout.addTab().id
        layout.selectTab(second)
        XCTAssertTrue(layout.removeTab(second))
        XCTAssertEqual(layout.selectedTab.id, third)
        let other = layout.addWorkspace(directory: "/tmp/two").id
        XCTAssertTrue(layout.removeTab(other))
        XCTAssertEqual(layout.selectedTab.id, third)
        XCTAssertTrue(layout.removeTab(third))
        XCTAssertEqual(layout.selectedTab.id, first)
        XCTAssertFalse(layout.removeTab(first))
        XCTAssertEqual(layout.workspaces.count, 1)
    }

    func testReorderingPreservesSessionIdentityAndPersistence() throws {
        var layout = WorkspaceLayout(directory: "/tmp/one")
        _ = layout.addTab()
        let selected = layout.selectedTab.id
        layout.moveTab(from: 1, to: 0)
        XCTAssertEqual(layout.selectedTab.id, selected)
        _ = layout.addWorkspace(directory: "/tmp/two")
        let active = layout.activeWorkspaceID
        layout.moveWorkspace(from: 1, to: 0)
        XCTAssertEqual(layout.activeWorkspaceID, active)
        XCTAssertEqual(layout.activeWorkspaceIndex, 0)
        XCTAssertEqual(WorkspaceLayout.restore(from: try JSONEncoder().encode(layout)), layout)
        layout.workspaces[0].tabs = []
        XCTAssertNil(WorkspaceLayout.restore(from: try JSONEncoder().encode(layout)))
    }

    func testDirectoryLabelsMatchRio() {
        XCTAssertEqual(TerminalWorkspace(directory: "/Users/test").displayName(home: "/Users/test"), "~")
        XCTAssertEqual(TerminalWorkspace(directory: "/Users/test/os/TabDance").displayName(home: "/Users/test"), "os")
        XCTAssertEqual(TerminalWorkspace(directory: "/Users/test-other/projects").displayName(home: "/Users/test"), "projects")
        XCTAssertEqual(TerminalTab(directory: "/").displayName, "/")
        XCTAssertEqual(TerminalTab(directory: "/tmp/one/../two").displayName, "two")
    }
}
