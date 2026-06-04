import SwiftUI

@main
struct GravitasRotoMotionApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    print("[RotoMotion App] ACTIVE ROOT VIEW = ContentView")
                }
        }
        .windowStyle(.titleBar)
    }
}
