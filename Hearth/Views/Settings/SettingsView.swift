import SwiftUI

struct SettingsView: View {
    let modelsManager: ModelsManager
    let promptsStore: PromptsStore
    let chatsStore: ChatsStore
    let preferences: Preferences
    let toolsStore: ToolsStore
    let projectsStore: ProjectsStore
    let voiceInput: VoiceInputService
    let sidecarsStore: SidecarsStore

    var body: some View {
        TabView {
            GeneralSettingsView(preferences: preferences, modelsManager: modelsManager)
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }
                .tag("general")

            ProjectsSettingsView(projectsStore: projectsStore, modelsManager: modelsManager)
                .tabItem { Label("Projects", systemImage: "folder.fill.badge.gearshape") }
                .tag("projects")

            ModelsSettingsView(modelsManager: modelsManager)
                .tabItem { Label("Models", systemImage: "shippingbox") }
                .tag("models")

            SidecarsSettingsView(sidecarsStore: sidecarsStore, modelsManager: modelsManager)
                .tabItem { Label("Sidecars", systemImage: "network") }
                .tag("sidecars")

            ChatsSettingsView(
                chatsStore: chatsStore,
                projectsStore: projectsStore,
                modelsManager: modelsManager
            )
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                .tag("chats")

            PromptsSettingsView(promptsStore: promptsStore)
                .tabItem { Label("Prompts", systemImage: "text.cursor") }
                .tag("prompts")

            ToolsSettingsView(toolsStore: toolsStore)
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
                .tag("tools")

            VoiceSettingsView(voiceInput: voiceInput)
                .tabItem { Label("Voice", systemImage: "mic") }
                .tag("voice")

            PermissionsSettingsView()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag("permissions")
        }
        .frame(width: 820, height: 600)
        .scenePadding()
    }
}
