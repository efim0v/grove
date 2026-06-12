import XCTest
import GroveCore
@testable import GroveAppKit

final class WorkspaceUsageTests: XCTestCase {
    func testWorkspaceUsageSumsTokensCostAndActiveAccounts() {
        // Two accounts active in one workspace (by its umbrella cwd).
        let analytics: [String: AccountUsageAnalytics] = [
            "default": stubAnalytics(cwd: "/ws/feat", input: 100, cost: 1.0, account: "default"),
            "work": stubAnalytics(cwd: "/ws/feat", input: 200, cost: 2.0, account: "work"),
        ]
        let ws = FeatureWorkspace(name: "feat", umbrellaPath: "/ws/feat", repos: [],
                                  parentName: nil,
                                  sessions: [ClaudeSession(id: "s1", cwd: "/ws/feat", title: nil,
                                             lastActivity: Date(), accountName: "default", gitBranch: nil)],
                                  liveProcesses: [], cmuxWorkspaces: [])
        let usage = workspaceUsage(workspace: ws, analyticsByAccount: analytics)
        XCTAssertEqual(usage.inputTokens, 300)
        XCTAssertEqual(usage.cost, 3.0, accuracy: 1e-9)
        XCTAssertEqual(usage.activeAccounts, ["default", "work"])   // sorted
    }

    private func stubAnalytics(cwd: String, input: Int, cost: Double,
                               account: String) -> AccountUsageAnalytics {
        AccountUsageAnalytics(accountName: account,
            today: UsageTotals(), thisMonth: UsageTotals(), last7d: UsageTotals(),
            sessions: [:], costByModel: [:],
            byCwd: [cwd: UsageTotals(inputTokens: input, cost: cost)],
            unpricedModels: [], unpricedCost: 0)
    }
}
