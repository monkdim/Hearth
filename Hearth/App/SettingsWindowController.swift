import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let modelsManager: ModelsManager
    private let promptsStore: PromptsStore
    private let chatsStore: ChatsStore
    private let preferences: Preferences
    private let toolsStore: ToolsStore
    private let projectsStore: ProjectsStore
    private let voiceInput: VoiceInputService
    private let sidecarsStore: SidecarsStore
    private var window: NSWindow?

    init(
        modelsManager: ModelsManager,
        promptsStore: PromptsStore,
        chatsStore: ChatsStore,
        preferences: Preferences,
        toolsStore: ToolsStore,
        projectsStore: ProjectsStore,
        voiceInput: VoiceInputService,
        sidecarsStore: SidecarsStore
    ) {
        self.modelsManager = modelsManager
        self.promptsStore = promptsStore
        self.chatsStore = chatsStore
        self.preferences = preferences
        self.toolsStore = toolsStore
        self.projectsStore = projectsStore
        self.voiceInput = voiceInput
        self.sidecarsStore = sidecarsStore
    }

    func show() {
        let win = window ?? makeWindow()
        window = win
        NSApp.activate(ignoringOtherApps: true)
        if !win.isVisible { win.center() }
        win.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hostingController = NSHostingController(
            rootView: SettingsView(
                modelsManager: modelsManager,
                promptsStore: promptsStore,
                chatsStore: chatsStore,
                preferences: preferences,
                toolsStore: toolsStore,
                projectsStore: projectsStore,
                voiceInput: voiceInput,
                sidecarsStore: sidecarsStore
            )
        )
        let win = NSWindow(contentViewController: hostingController)
        win.title = "Hearth Settings"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 820, height: 600))
        win.delegate = self
        return win
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
