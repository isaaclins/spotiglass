import SwiftUI

@main
struct SpotiglassApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 520, minHeight: 360)
        }
        .windowResizability(.contentMinSize)
    }
}
