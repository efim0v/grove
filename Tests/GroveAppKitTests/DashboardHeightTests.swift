import XCTest
import SwiftUI
import GroveCore
@testable import GroveAppKit

/// The usage panel must not resize when you page through scopes with ‹ ›. Scopes
/// genuinely differ in content — Overall can carry several model bars and a chip
/// line that an account column has neither of — so the panel sizes to the TALLEST
/// scope and pins its content to the top.
@MainActor
final class DashboardHeightTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    /// Three accounts on two different models: Overall gets two model bars plus chip
    /// lines, each account column gets one bar and no chips — the tallest and the
    /// shortest scope in one fixture.
    private func state() throws -> AppState {
        let root = try FixtureLite.tempDir("dash-height")
        let s = AppState(configStore: ConfigStore(url: root.appendingPathComponent("c.json")))
        let future = ISO8601DateFormatter().string(from: now.addingTimeInterval(86_400))
        func snapshot(_ account: String, model: String) -> UsageSnapshot {
            UsageSnapshot(accountName: account, sessionId: "oauth", capturedAt: now, cwd: nil,
                          modelId: nil, modelDisplayName: nil, effort: nil,
                          contextUsedPercentage: nil, totalInputTokens: nil, totalCostUSD: nil,
                          fiveHour: CapturedWindow(usedPercentage: 30, resetsAt: future),
                          sevenDay: CapturedWindow(usedPercentage: 40, resetsAt: future),
                          weeklyScopedWindow: CapturedWindow(usedPercentage: 50, resetsAt: future),
                          weeklyScopedModel: model)
        }
        s.config.accounts = [
            AccountConfig(name: "work", configDir: "/tmp/w"),
            AccountConfig(name: "personal", configDir: "/tmp/p"),
            AccountConfig(name: "apple", configDir: "/tmp/a"),
        ]
        s.snapshotsByAccount = [
            "work": [snapshot("work", model: "Fable")],
            "personal": [snapshot("personal", model: "Fable")],
            "apple": [snapshot("apple", model: "Opus")],
        ]
        s.usageDataAsOf = now
        return s
    }

    /// Natural rendered height of the panel at a given scope.
    private func height(_ s: AppState, scope: Int) -> CGFloat {
        s.chartsScopeIndex = scope
        let renderer = ImageRenderer(content:
            ChartsSideContent(state: s)
                .environment(\.isSnapshotRender, true)
                .environment(\.colorScheme, .dark))
        renderer.scale = 1
        return CGFloat(renderer.cgImage?.height ?? 0)
    }

    func testPanelHeightIsIdenticalAcrossScopes() throws {
        let s = try state()
        let heights = (0..<4).map { height(s, scope: $0) }
        XCTAssertTrue(heights.allSatisfy { $0 > 0 }, "nothing rendered: \(heights)")
        XCTAssertEqual(Set(heights).count, 1,
                       "the panel must not resize between scopes, got \(heights)")
    }
}
