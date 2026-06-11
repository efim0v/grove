import XCTest
import SwiftUI
@testable import GroveAppKit

/// PanelOverlay replaces real `.sheet` windows inside the MenuBarExtra panel
/// (a second key window auto-hides the panel). These tests render small views
/// through ImageRenderer and sample pixels: overlay absent -> backdrop pixels
/// untouched; overlay presented -> backdrop dimmed and content drawn on top.
final class PanelOverlayTests: XCTestCase {

    private struct Token: Identifiable {
        let id: Int
    }

    // MARK: - Rendering / sampling helpers

    @MainActor
    private func render(_ view: some View) throws -> CGImage {
        let renderer = ImageRenderer(content: view
            .frame(width: 200, height: 200)
            .environment(\.isSnapshotRender, true))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer produced no image")
        return image
    }

    /// sRGB components at (x, y) in top-left coordinates, 0...1.
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (r: Double, g: Double, b: Double) {
        var data = [UInt8](repeating: 0, count: 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -CGFloat(x), y: -CGFloat(image.height - 1 - y),
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Double(data[0]) / 255, Double(data[1]) / 255, Double(data[2]) / 255)
    }

    // MARK: - isPresented variant

    @MainActor
    func testHiddenWhenNotPresented() throws {
        let image = try render(
            Color.white.panelOverlay(isPresented: .constant(false)) { Color.red }
        )
        let corner = try pixel(image, x: 10, y: 10)
        XCTAssertGreaterThan(corner.r, 0.95)
        XCTAssertGreaterThan(corner.g, 0.95)
        XCTAssertGreaterThan(corner.b, 0.95)
    }

    @MainActor
    func testPresentedDimsBackdropAndCentersContent() throws {
        let image = try render(
            Color.white.panelOverlay(isPresented: .constant(true)) {
                Color.red.frame(width: 60, height: 60)
            }
        )
        // Backdrop corner: white under Color.black.opacity(0.45) -> mid gray.
        let corner = try pixel(image, x: 10, y: 10)
        XCTAssertLessThan(corner.r, 0.75, "backdrop should be dimmed")
        XCTAssertGreaterThan(corner.r, 0.30, "dim layer must not be opaque black")
        // Center: the red content card sits on top.
        let center = try pixel(image, x: 100, y: 100)
        XCTAssertGreaterThan(center.r, 0.6)
        XCTAssertLessThan(center.g, 0.4)
    }

    // MARK: - item variant

    @MainActor
    func testItemNilRendersNoOverlay() throws {
        let image = try render(
            Color.white.panelOverlay(item: .constant(Token?.none)) { _ in Color.green }
        )
        let center = try pixel(image, x: 100, y: 100)
        XCTAssertGreaterThan(center.r, 0.95)
        XCTAssertGreaterThan(center.g, 0.95)
        XCTAssertGreaterThan(center.b, 0.95)
    }

    @MainActor
    func testItemPresentsContentForThatItem() throws {
        let image = try render(
            Color.white.panelOverlay(item: .constant(Token(id: 7))) { token in
                (token.id == 7 ? Color.green : Color.red).frame(width: 60, height: 60)
            }
        )
        let center = try pixel(image, x: 100, y: 100)
        XCTAssertGreaterThan(center.g, 0.5, "content built from the bound item should render")
        XCTAssertLessThan(center.r, 0.5)
        // Backdrop is dimmed here too.
        let corner = try pixel(image, x: 10, y: 10)
        XCTAssertLessThan(corner.r, 0.75)
    }
}
