import XCTest
import SwiftUI
import AppKit
@testable import GroveAppKit

@MainActor
final class WindowSubstrateTests: XCTestCase {

    private func makePanelAndHost() -> (NSPanel, NSHostingController<AnyView>) {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                        styleMask: [.borderless], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        let h = NSHostingController(rootView: AnyView(Color.clear))
        return (p, h)
    }

    func testStyleDefaultsToLiquidGlassAndPersists() {
        let key = WindowSubstrateStyle.defaultsKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(WindowSubstrateStyle.current, .liquidGlass)           // unset → default
        UserDefaults.standard.set(WindowSubstrateStyle.visualEffect.rawValue, forKey: key)
        XCTAssertEqual(WindowSubstrateStyle.current, .visualEffect)          // round-trips
        UserDefaults.standard.set("garbage", forKey: key)
        XCTAssertEqual(WindowSubstrateStyle.current, .liquidGlass)           // unknown → default
    }

    func testInstallVisualEffectIsConstantBehindWindowSubstrate() {
        let (p, h) = makePanelAndHost()
        WindowSubstrate.install(h, radius: 12, style: .visualEffect, in: p)
        guard let effect = p.contentView as? NSVisualEffectView else {
            return XCTFail("expected an NSVisualEffectView substrate")
        }
        // The M1 recipe: always-active (never dims on key change), behind-window,
        // very transparent material, clipped to the panel radius, host embedded.
        XCTAssertEqual(effect.state, .active)
        XCTAssertEqual(effect.blendingMode, .behindWindow)
        XCTAssertEqual(effect.material, .hudWindow)
        XCTAssertEqual(effect.layer?.cornerRadius, 12)
        XCTAssertTrue(effect.subviews.contains(h.view))
    }

    func testInstallLiquidGlassUsesGlassSubstrate() {
        let (p, h) = makePanelAndHost()
        WindowSubstrate.install(h, radius: 12, style: .liquidGlass, in: p)
        XCTAssertTrue(p.contentView is NSGlassEffectView)
    }

    func testReinstallLiveSwapsSubstrateReparentingTheSameHost() {
        let (p, h) = makePanelAndHost()
        WindowSubstrate.install(h, radius: 12, style: .liquidGlass, in: p)
        XCTAssertTrue(p.contentView is NSGlassEffectView)

        WindowSubstrate.install(h, radius: 12, style: .visualEffect, in: p)
        guard let effect = p.contentView as? NSVisualEffectView else {
            return XCTFail("expected the substrate to swap to NSVisualEffectView")
        }
        // The SAME hosting view is re-parented into the new backing (live swap, no loss).
        XCTAssertTrue(effect.subviews.contains(h.view))
        XCTAssertFalse(h.view.superview is NSGlassEffectView)
    }
}
