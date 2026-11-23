import SwiftUI
import VervangingCore

@main
struct VervangingApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// The first screen: Spelers, with the roster saved on the phone (#100). Later tickets add the Match screen.
struct RootView: View {
    var body: some View {
        NavigationStack {
            SpelersScreen(store: .standard())
        }
    }
}

#Preview {
    RootView()
}
