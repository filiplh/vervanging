import SwiftUI

/// Which layout a screen takes (plan decision #41): the wide layout when the room the screen has is at least 600 pt wide
/// and 500 pt tall, the phone layout otherwise. It looks only at the size, never at the device model, so the iPhone 17
/// Pro (402 pt wide) and the iPhone Duo's outer screen (466 pt) keep the phone layout in portrait, and stay too short
/// for the wide one in landscape, while the Duo's inner screen (669 × 951 pt) takes it either way round. Unfolding or
/// folding the Duo changes the size of the same window, so a screen switches layout with its state as it was.
/// ⚠ The inner screen's size comes from the simulator's display list; the layout was not seen on it (plan assumption A6).
enum WideLayout {
    /// The least room for the wide layout, in points, measured inside the safe area and the bars.
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

    static func isWide(_ size: CGSize) -> Bool {
        size.width >= minimum.width && size.height >= minimum.height
    }
}

extension View {
    /// Keeps `wide` up to date with the room this view gets.
    func measuresWideLayout(_ wide: Binding<Bool>) -> some View {
        onGeometryChange(for: Bool.self) { WideLayout.isWide($0.size) } action: { wide.wrappedValue = $0 }
    }
}
