import SwiftUI

@main
struct HearthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A SwiftUI `App` requires at least one Scene. The launcher window is
        // managed in AppKit (NSPanel) and Settings is its own NSWindow, so this
        // Settings scene is intentionally empty.
        Settings {
            EmptyView()
        }
    }
}
