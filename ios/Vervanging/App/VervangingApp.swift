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

/// The first screen: empty for now, titled with the app's name. Later tickets put the setup screen here.
struct RootView: View {
    var body: some View {
        NavigationStack {
            Color.clear
                .navigationTitle("Vervanging")
        }
    }
}

#Preview {
    RootView()
}
