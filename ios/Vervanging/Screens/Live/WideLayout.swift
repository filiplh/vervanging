import SwiftUI

/// Which layout a screen takes (plan decision #41): the wide layout when the window is at least 600 pt wide and 500 pt
/// tall, the phone layout otherwise. It looks only at the size, never at the device model, so the iPhone 17 Pro (402 pt
/// wide) and the iPhone Duo's outer screen (466 pt) keep the phone layout in portrait, and stay too short for the wide
/// one in landscape, while the Duo's inner screen (669 × 951 pt) takes it either way round. Unfolding or folding the Duo
/// changes the size of the same window, so a screen switches layout with its state as it was.
///
/// It measures the whole window, bars and safe area included, not the room between the bars: that room grows when the
/// navigation bar shrinks during a scroll, and on the inner screen it once crossed the threshold mid-scroll, so the live
/// screen swapped layouts under the coach's finger (#143). The window only changes size when the Duo is folded,
/// unfolded or turned.
/// ⚠ The inner screen's size comes from the simulator's display list; the layout was not seen on it (plan assumption A6).
enum WideLayout {
    /// The phone layout, or the wide layout in a window taller than wide (the inner screen upright) or wider than tall
    /// (the inner screen turned).
    enum Kind: Equatable {
        case phone, portrait, landscape

        var isWide: Bool { self != .phone }
    }

    /// The least window for the wide layout, in points.
    static let minimum: CGSize = {
        #if DEBUG
        // UI tests lower it ("500x0") to drive the switch by turning a phone sideways: the simulator cannot unfold the
        // Duo. Debug builds only.
        if let text = ProcessInfo.processInfo.environment["VERVANGING_WIDE_LAYOUT_MIN"] {
            let parts = text.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { return CGSize(width: parts[0], height: parts[1]) }
        }
        #endif
        return CGSize(width: 600, height: 500)
    }()

    static func kind(_ window: CGSize) -> Kind {
        guard window.width >= minimum.width, window.height >= minimum.height else { return .phone }
        return window.width > window.height ? .landscape : .portrait
    }
}

extension View {
    /// Keeps `kind` up to date with the window this view sits in: the view's size plus the safe area around it (the
    /// bars, the status bar, the home indicator). When the navigation bar shrinks during a scroll the view grows by what
    /// the safe area loses, so the sum, and the layout, stay as they were.
    func measuresWideLayout(_ kind: Binding<WideLayout.Kind>) -> some View {
        onGeometryChange(for: WideLayout.Kind.self) { proxy in
            let insets = proxy.safeAreaInsets
            return WideLayout.kind(CGSize(width: proxy.size.width + insets.leading + insets.trailing,
                                          height: proxy.size.height + insets.top + insets.bottom))
        } action: {
            kind.wrappedValue = $0
        }
    }
}
