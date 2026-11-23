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

/// Two tabs, as the web app's "Spelers" and "Match": the roster (#100) and the match setup (#101). The app opens on
/// Spelers; later tickets add the live screen.
struct RootView: View {
    private enum Screen: Hashable { case spelers, match }

    @State private var screen = Screen.spelers

    var body: some View {
        TabView(selection: $screen) {
            Tab("Spelers", systemImage: "person.3", value: Screen.spelers) {
                NavigationStack {
                    SpelersScreen(store: .standard())
                }
            }
            Tab("Match", systemImage: "sportscourt", value: Screen.match) {
                NavigationStack {
                    SetupScreen(rosterStore: .standard(), setupStore: .standard(), onShowSpelers: { screen = .spelers })
                }
            }
        }
    }
}

#Preview {
    RootView()
}
