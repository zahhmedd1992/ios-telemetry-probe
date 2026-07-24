import SwiftUI

@main
struct ProbeApp: App {
    @StateObject private var runner = ProbeRunner()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(runner)
                .preferredColorScheme(.dark)
        }
    }
}
