import AppKit
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.colbydimaggio.hearth", category: "AppDelegate")
    private let appState: AppState
    private let hotkeyManager = HotkeyManager()
    let modelsManager: ModelsManager
    let promptsStore: PromptsStore
    let chatsStore: ChatsStore
    let preferences: Preferences
    let toolsStore: ToolsStore
    let projectsStore: ProjectsStore
    let ltmExtractor: LTMExtractor
    let voiceInput: VoiceInputService
    let sidecarsStore: SidecarsStore
    let apiServerStore: APIServerStore
    private var apiServer: HearthAPIServer?

    override init() {
        // Migration MUST run before any store initializes so the stores find
        // the existing Application Support data and UserDefaults values.
        Migration.runIfNeeded()
        let appState = AppState()
        let sidecarsStore = SidecarsStore()
        let modelsManager = ModelsManager(sidecars: sidecarsStore.sidecars)
        let projectsStore = ProjectsStore()
        self.appState = appState
        self.sidecarsStore = sidecarsStore
        self.modelsManager = modelsManager
        self.promptsStore = PromptsStore()
        self.chatsStore = ChatsStore()
        self.preferences = Preferences()
        self.toolsStore = ToolsStore()
        self.projectsStore = projectsStore
        self.ltmExtractor = LTMExtractor(
            modelsManager: modelsManager,
            projectsStore: projectsStore,
            appState: appState
        )
        self.voiceInput = VoiceInputService()
        self.apiServerStore = APIServerStore()
        super.init()
    }
    private lazy var generationController = GenerationController(
        appState: appState,
        modelsManager: modelsManager,
        chatsStore: chatsStore,
        preferences: preferences,
        toolsStore: toolsStore,
        projectsStore: projectsStore
    )
    private lazy var windowManager = WindowManager(
        appState: appState,
        controller: generationController,
        promptsStore: promptsStore,
        chatsStore: chatsStore,
        modelsManager: modelsManager,
        preferences: preferences,
        projectsStore: projectsStore,
        ltmExtractor: ltmExtractor,
        voiceInput: voiceInput
    )
    private lazy var settingsController = SettingsWindowController(
        modelsManager: modelsManager,
        promptsStore: promptsStore,
        chatsStore: chatsStore,
        preferences: preferences,
        toolsStore: toolsStore,
        projectsStore: projectsStore,
        voiceInput: voiceInput,
        sidecarsStore: sidecarsStore,
        apiServerStore: apiServerStore,
        onAPIServerSettingsChanged: { [weak self] in self?.applyAPIServerSettings() }
    )
    private lazy var aboutController = AboutWindowController()
    private var statusItem: NSStatusItem?
    private var modelsSubmenu: NSMenu?
    private var projectsSubmenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        installHotkey()
        requestAccessibilityOnce()
        applyAPIServerSettings()
    }

    /// Start / restart / stop the local OpenAI-compatible HTTP server based on
    /// the current settings. Called at launch and whenever the user toggles
    /// the switch or changes the port in Settings → API Server.
    func applyAPIServerSettings() {
        let store = apiServerStore
        let manager = modelsManager
        let tools = toolsStore
        let projects = projectsStore
        if store.isEnabled {
            if apiServer == nil {
                apiServer = HearthAPIServer(
                    engineProvider: { manager.engine },
                    modelIdProvider: { manager.activeModel.id },
                    tokenProvider: { store.token },
                    toolboxProvider: {
                        // Same toolbox the launcher chat uses, so file_read /
                        // list_directory / find_files / custom shell tools are
                        // available to anything calling the API (OpenClaw, IDE
                        // plugins, scripts).
                        ToolBoxFactory.build(from: tools.enabledTools)
                    },
                    promptContextProvider: {
                        // Seed the system prompt with the active project's
                        // root + LTM so "what's in my repo?" works without the
                        // caller having to pass paths through.
                        let project = projects.activeProject
                        let workingDir = project.rootPath
                            .map { NSString(string: $0).expandingTildeInPath }
                        return InferenceEngine.PromptContext(
                            projectName: project.name,
                            workingDirectory: workingDir,
                            ltm: project.ltm
                        )
                    }
                )
            }
            let port = store.port
            let server = apiServer
            Task { await server?.start(port: port) }
        } else {
            let server = apiServer
            Task { await server?.stop() }
        }
    }

    private func requestAccessibilityOnce() {
        let key = "hearth.didRequestAccessibility"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        _ = ContextProvider.requestAccessibilityIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.unregister()
        chatsStore.saveNow()
        projectsStore.saveNow()
        let server = apiServer
        Task { await server?.stop() }
    }

    // MARK: - Status bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "Hearth")
        }

        let menu = NSMenu()
        menu.delegate = self

        let open = NSMenuItem(title: "Open Launcher", action: #selector(togglePanel), keyEquivalent: " ")
        open.keyEquivalentModifierMask = .option
        open.target = self
        menu.addItem(open)

        let newChat = NSMenuItem(title: "New Chat", action: #selector(newChat), keyEquivalent: "n")
        newChat.target = self
        menu.addItem(newChat)

        menu.addItem(.separator())

        let projectsItem = NSMenuItem(title: "Active Project", action: nil, keyEquivalent: "")
        let projectsSub = NSMenu(title: "Active Project")
        projectsItem.submenu = projectsSub
        projectsSubmenu = projectsSub
        menu.addItem(projectsItem)

        let modelsItem = NSMenuItem(title: "Active Model", action: nil, keyEquivalent: "")
        let modelsSub = NSMenu(title: "Active Model")
        modelsItem.submenu = modelsSub
        modelsSubmenu = modelsSub
        menu.addItem(modelsItem)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let about = NSMenuItem(title: "About Hearth", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Hearth",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    private func rebuildProjectsSubmenu() {
        guard let submenu = projectsSubmenu else { return }
        submenu.removeAllItems()
        for project in projectsStore.projects {
            let item = NSMenuItem(title: project.name, action: #selector(pickProject(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = project.id.uuidString
            if project.id == projectsStore.activeProjectId {
                item.state = .on
            }
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage Projects…", action: #selector(openSettings), keyEquivalent: "")
        manage.target = self
        submenu.addItem(manage)
    }

    @objc private func pickProject(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString) else { return }
        projectsStore.setActive(id)
        // Also swap the active model to the project's preference, if any.
        if let project = projectsStore.project(with: id),
           let preferred = project.modelId,
           let model = modelsManager.availableModels.first(where: { $0.id == preferred }),
           modelsManager.installationState(for: model).isInstalled {
            modelsManager.setActive(model)
        }
    }

    private func rebuildModelsSubmenu() {
        guard let submenu = modelsSubmenu else { return }
        submenu.removeAllItems()

        let installed = modelsManager.availableModels.filter {
            modelsManager.installationState(for: $0).isInstalled
        }

        if installed.isEmpty {
            let placeholder = NSMenuItem(title: "No models installed yet", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            submenu.addItem(placeholder)
            submenu.addItem(.separator())
            let openSettingsItem = NSMenuItem(title: "Open Settings to install…", action: #selector(openSettings), keyEquivalent: "")
            openSettingsItem.target = self
            submenu.addItem(openSettingsItem)
            return
        }

        for model in installed {
            let item = NSMenuItem(title: model.displayName, action: #selector(pickModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model.id
            if model.id == modelsManager.activeModel.id {
                item.state = .on
            }
            submenu.addItem(item)
        }
    }

    // MARK: - Hotkey

    private func installHotkey() {
        hotkeyManager.onHotkey = { [weak self] in
            self?.windowManager.togglePanel()
        }
        do {
            try hotkeyManager.register()
            logger.info("Registered global hotkey ⌥Space")
        } catch {
            logger.error("Hotkey registration failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Actions

    @objc private func togglePanel() {
        windowManager.togglePanel()
    }

    @objc private func newChat() {
        chatsStore.startNewChat()
        windowManager.showPanel()
    }

    @objc private func openSettings() {
        settingsController.show()
    }

    @objc private func openAbout() {
        aboutController.show()
    }

    @objc private func pickModel(_ sender: NSMenuItem) {
        guard let modelId = sender.representedObject as? String,
              let model = modelsManager.availableModels.first(where: { $0.id == modelId }) else { return }
        modelsManager.setActive(model)
    }
}

// MARK: - Menu refresh

extension AppDelegate: NSMenuDelegate {
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in
            self.rebuildModelsSubmenu()
            self.rebuildProjectsSubmenu()
        }
    }
}
