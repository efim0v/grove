import Foundation
@testable import GroveCore

/// CmuxScripting double: records every call, replays canned results, and never
/// touches the real cmux. `running` models NSRunningApplication availability.
final class MockScripting: CmuxScripting, @unchecked Sendable {
    enum Call: Equatable {
        case list
        case newWorkspace(cwd: String, command: String?, focus: Bool)
        case select(tabId: String)
        case close(tabId: String)
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let running: Bool
    private let listResult: [CmuxWorkspace]

    init(running: Bool, listResult: [CmuxWorkspace] = []) {
        self.running = running
        self.listResult = listResult
    }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private func record(_ call: Call) {
        lock.lock(); recorded.append(call); lock.unlock()
    }

    func isAppRunning() -> Bool { running }

    func listWorkspaces() async throws -> [CmuxWorkspace] {
        record(.list)
        return listResult
    }

    func newWorkspace(cwd: String, command: String?, focus: Bool) async throws {
        record(.newWorkspace(cwd: cwd, command: command, focus: focus))
    }

    func selectWorkspace(tabId: String) async throws {
        record(.select(tabId: tabId))
    }

    func closeWorkspace(tabId: String) async throws {
        record(.close(tabId: tabId))
    }
}
