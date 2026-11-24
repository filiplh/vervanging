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

/// Two tabs, as the web app's "Spelers" and "Match": the roster (#100) and the match setup (#101), with the live
/// screen (#102) opened from setup's Start. The app opens on Spelers, or on the live screen when a match is running,
/// so the coach gets back to it after a force-quit (`defaultView` in `public/js/app.js`).
struct RootView: View {
    private enum Screen: Hashable { case spelers, match }
    private enum MatchRoute: Hashable { case live }

    private let matchStore = MatchStore.standard()

    @State private var screen: Screen
    @State private var matchPath: [MatchRoute]
    @State private var live: LiveModel?

    init() {
        let stored = MatchStore.standard().load()
        let model = stored.map { LiveModel(match: $0, store: MatchStore.standard()) }
        let running = model?.isRunning == true
        _live = State(initialValue: model)
        _screen = State(initialValue: running ? .match : .spelers)
        _matchPath = State(initialValue: running ? [.live] : [])
    }

    var body: some View {
        TabView(selection: $screen) {
            Tab("Spelers", systemImage: "person.3", value: Screen.spelers) {
                NavigationStack {
                    SpelersScreen(store: .standard())
                }
            }
            Tab("Match", systemImage: "sportscourt", value: Screen.match) {
                NavigationStack(path: $matchPath) {
                    SetupScreen(rosterStore: .standard(), setupStore: .standard(),
                                onShowSpelers: { screen = .spelers },
                                onStart: startMatch,
                                runningMatch: live?.isRunning == true ? { matchPath = [.live] } : nil)
                        .navigationDestination(for: MatchRoute.self) { _ in
                            if let live {
                                LiveScreen(model: live, onNewMatch: { matchPath = [] })
                            }
                        }
                }
            }
        }
        #if DEBUG
        .overlay(alignment: .topLeading) { ScreenAwakeProbe() }
        #endif
    }

    /// A started match replaces the one before (setup asked first when it was still running) and opens live.
    private func startMatch(_ started: StartedMatch) {
        live = LiveModel.start(started, store: matchStore)
        matchPath = [.live]
    }
}

#if DEBUG
/// Lets the UI tests read whether the screen is kept awake (decision #18): an invisible element whose value is what
/// the system's idle timer switch says now. Debug builds only.
private struct ScreenAwakeProbe: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityIdentifier("debug.screenAwake")
            .accessibilityValue(Text(verbatim: ScreenAwake.shared.isOn ? "on" : "off"))
    }
}
#endif

#Preview {
    RootView()
}
