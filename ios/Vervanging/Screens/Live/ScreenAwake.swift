import Observation
import UIKit

/// Keeps the screen from dimming and locking while a match runs (plan decision #18), the native twin of the web app's
/// wake lock (`keepScreenAwake` in `public/js/live.js`). SwiftUI has no way to do this, so it sets UIKit's idle timer
/// switch (plan decision #37 allows UIKit where SwiftUI cannot). The live screen turns it on while the match runs and
/// off when the match ends or the screen closes.
@MainActor
@Observable
final class ScreenAwake {
    static let shared = ScreenAwake()

    /// What the system says now, read back after every change.
    private(set) var isOn = UIApplication.shared.isIdleTimerDisabled

    func set(_ on: Bool) {
        if UIApplication.shared.isIdleTimerDisabled != on { UIApplication.shared.isIdleTimerDisabled = on }
        isOn = UIApplication.shared.isIdleTimerDisabled
    }
}
