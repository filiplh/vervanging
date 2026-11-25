#if DEBUG
import SwiftUI
import UIKit

/// Debug builds only (#143): shows the live screen in a window of a set size, scaled down to fit the simulator's screen,
/// so UI tests and screenshots can check the iPhone Duo's inner screen, which the simulator cannot unfold. Its views lay
/// out at the full size, in points, inside the set safe area; only the picture is scaled. ⚠ Where the simulator's own
/// safe area is larger than the set one (its status bar and home indicator, or its side insets when turned), it still
/// applies: the tests show the turned canvas on a turned phone, which has no status bar on top, and the upright canvas
/// on an upright phone.
///
/// `VERVANGING_CANVAS` names the size and, after `@`, the safe area (top, leading, bottom, trailing):
/// "951x669@0,0,31,83" is the inner screen turned. With `VERVANGING_CANVAS_SHOTS` set to a folder on the Mac, each
/// action and each change of In the zone also saves the canvas at full resolution there.
@MainActor
enum DebugCanvas {
    struct Spec {
        var size: CGSize
        var insets: EdgeInsets
    }

    static let spec: Spec? = {
        guard let text = ProcessInfo.processInfo.environment["VERVANGING_CANVAS"], !text.isEmpty else { return nil }
        let parts = text.split(separator: "@")
        let size = parts[0].split(separator: "x").compactMap { Double($0) }
        guard size.count == 2 else { return nil }
        var insets = EdgeInsets()
        if parts.count > 1 {
            let edges = parts[1].split(separator: ",").compactMap { Double($0) }
            if edges.count == 4 {
                insets = EdgeInsets(top: edges[0], leading: edges[1], bottom: edges[2], trailing: edges[3])
            }
        }
        return Spec(size: CGSize(width: size[0], height: size[1]), insets: insets)
    }()

    private static var window: UIWindow?
    private static var shots = 0

    /// Shows `content` in the canvas window, above the app.
    static func show<Content: View>(_ content: Content) {
        guard let spec, window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        // The canvas ignores the simulator's own safe area; the one it was given keeps the screen clear of the edges,
        // as the status bar, the home indicator and the column with the time do on the Duo.
        let host = UIHostingController(rootView: content.padding(spec.insets))
        host.safeAreaRegions = []
        // The inner screen is tall and wide: regular size classes, so a turned phone does not give the canvas the
        // shorter navigation bar it has itself.
        host.traitOverrides.horizontalSizeClass = .regular
        host.traitOverrides.verticalSizeClass = .regular
        let canvas = UIWindow(windowScene: scene)
        canvas.rootViewController = host
        canvas.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        canvas.accessibilityIdentifier = "debug.canvas"
        let screen = scene.effectiveGeometry.coordinateSpace.bounds
        let scale = min(screen.width / spec.size.width, screen.height / spec.size.height)
        canvas.bounds = CGRect(origin: .zero, size: spec.size)
        canvas.transform = CGAffineTransform(scaleX: scale, y: scale)
        canvas.center = CGPoint(x: screen.midX, y: screen.midY)
        canvas.isHidden = false
        window = canvas
    }

    static func hide() {
        window?.isHidden = true
        window = nil
    }

    /// Saves the canvas at full resolution once the change has settled, when `VERVANGING_CANVAS_SHOTS` is set.
    static func shot() {
        guard let folder = ProcessInfo.processInfo.environment["VERVANGING_CANVAS_SHOTS"], !folder.isEmpty,
              let spec else { return }
        shots += 1
        let name = "canvas-\(Int(spec.size.width))x\(Int(spec.size.height))-\(shots).png"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let window else { return }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let url = URL(fileURLWithPath: folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? image.pngData()?.write(to: url.appendingPathComponent(name))
        }
    }
}
#endif
