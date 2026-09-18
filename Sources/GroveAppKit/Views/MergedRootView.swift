import SwiftUI

/// The ONE SwiftUI root the menu-bar panel hosts: the projects section (`RootView`)
/// under the window's glass substrate, traced by the single rounded hairline. The
/// usage-charts column that used to sit beside it belongs to Brow now.
///
/// A named `View` (not an inline expression in `makePanel`) so it stays
/// snapshot-testable and keeps the height cap in one place.
public struct MergedRootView: View {
    @ObservedObject private var state: AppState

    public init(state: AppState) {
        _state = ObservedObject(wrappedValue: state)
    }

    public var body: some View {
        RootView(state: state)
            .frame(maxHeight: Self.maxRootHeight, alignment: .top)
            .overlay(
                RoundedRectangle(cornerRadius: DesignRadius.panel, style: .continuous)
                    .strokeBorder(.white.opacity(0.10))
            )
    }

    /// The tallest the root may be: the main screen's visible height (minus a small
    /// margin), so the window can't grow off-screen. Read at render time; a stale
    /// value after a display change self-corrects on the next render.
    static var maxRootHeight: CGFloat {
        max(320, (NSScreen.main?.visibleFrame.height ?? 1200) - 8)
    }
}
