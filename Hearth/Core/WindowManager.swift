import AppKit
import SwiftUI

/// Borderless, non-activating panel that hosts the launcher UI.
/// Overriding `canBecomeKey` lets the embedded SwiftUI TextField receive
/// keystrokes without forcing the app to the foreground.
final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WindowManager {
    private let appState: AppState
    private let controller: GenerationController
    private let promptsStore: PromptsStore
    private let chatsStore: ChatsStore
    private let modelsManager: ModelsManager
    private let preferences: Preferences
    private let projectsStore: ProjectsStore
    private let ltmExtractor: LTMExtractor
    private let voiceInput: VoiceInputService
    private var panel: LauncherPanel?
    private var frameObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    private var becameKeyObserver: NSObjectProtocol?
    /// When the panel most recently became the key window. We use this to
    /// reject ESC dismisses that arrive too soon after focus returns — e.g.,
    /// when the macOS Screenshot tool hands control back and a stray ESC
    /// keystroke propagates into our window.
    private var lastBecameKeyAt: Date = .distantPast
    /// Screen-space Y coordinate of the panel's top edge while visible.
    /// Used to anchor the top as the panel grows.
    private var anchoredTopY: CGFloat?
    /// Re-entry guard for the anchor logic. Without this, `panel.setFrame`
    /// can re-trigger the contentView frame observer on the same runloop pass
    /// and the chain has nowhere to terminate.
    private var isAnchoring: Bool = false

    init(
        appState: AppState,
        controller: GenerationController,
        promptsStore: PromptsStore,
        chatsStore: ChatsStore,
        modelsManager: ModelsManager,
        preferences: Preferences,
        projectsStore: ProjectsStore,
        ltmExtractor: LTMExtractor,
        voiceInput: VoiceInputService
    ) {
        self.appState = appState
        self.controller = controller
        self.promptsStore = promptsStore
        self.chatsStore = chatsStore
        self.modelsManager = modelsManager
        self.preferences = preferences
        self.projectsStore = projectsStore
        self.ltmExtractor = ltmExtractor
        self.voiceInput = voiceInput
    }

    deinit {
        if let frameObserver {
            NotificationCenter.default.removeObserver(frameObserver)
        }
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        if let becameKeyObserver {
            NotificationCenter.default.removeObserver(becameKeyObserver)
        }
    }

    /// Called from the panel's ESC handler. Refuses to dismiss if the panel
    /// only just became key — that usually means focus is returning from
    /// another system service (screenshot tool, etc.) and the ESC isn't ours.
    /// Cleaner than disabling ESC entirely.
    func attemptEscapeDismiss() {
        let sinceFocus = Date().timeIntervalSince(lastBecameKeyAt)
        guard sinceFocus > 0.5 else { return }
        hidePanel()
    }

    func togglePanel() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        // Make sure there's a current chat so the project/folder pickers in
        // the header are immediately available — even before the user types.
        chatsStore.ensureCurrentChat(projectId: projectsStore.activeProjectId)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        positionPanel(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.13
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        captureContext()
    }

    func hidePanel() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            panel?.orderOut(nil)
            self?.appState.capturedContext = nil
            self?.appState.activeShortcut = nil
            self?.appState.query = ""
        }
    }

    /// Kicks off an AX/clipboard capture without blocking the panel. The
    /// frontmost app reference is snapshotted before the panel becomes key —
    /// our panel is `.nonactivatingPanel` so the user's previous app stays
    /// frontmost, but we capture early to be safe.
    private func captureContext() {
        appState.capturedContext = nil
        Task { [weak appState] in
            let captured = await ContextProvider.capture()
            await MainActor.run {
                appState?.capturedContext = captured
            }
        }
    }

    /// Panel size that matches LauncherView's explicit `.frame` — keep these
    /// in sync. We re-enable auto-sizing now that SwiftUI always reports a
    /// fixed preferred size; the previous loop happened because the SwiftUI
    /// content's height was intrinsic and varied between renders.
    private static let panelSize = NSSize(width: LauncherView.fixedWidth,
                                          height: LauncherView.fixedHeight)

    private func makePanel() -> LauncherPanel {
        let panel = LauncherPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let rootView = LauncherView(
            appState: appState,
            controller: controller,
            promptsStore: promptsStore,
            chatsStore: chatsStore,
            modelsManager: modelsManager,
            projectsStore: projectsStore,
            ltmExtractor: ltmExtractor,
            voiceInput: voiceInput,
            onDismiss: { [weak self] in self?.hidePanel() },
            onEscape: { [weak self] in self?.attemptEscapeDismiss() }
        )

        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hostingController
        panel.setContentSize(Self.panelSize)

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak panel] _ in
            guard let panel, let self else { return }
            MainActor.assumeIsolated {
                if self.preferences.positionMode == .rememberLast {
                    self.preferences.lastPanelOrigin = panel.frame.origin
                }
            }
        }

        becameKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.lastBecameKeyAt = Date()
            }
        }

        return panel
    }

    /// Positions the panel based on the user's preference: either centered on
    /// the active screen (upper third) or remembered from last time.
    private func positionPanel(_ panel: NSPanel) {
        switch preferences.positionMode {
        case .rememberLast:
            if let origin = preferences.lastPanelOrigin, isOnScreen(origin) {
                panel.setFrameOrigin(origin)
                anchoredTopY = origin.y + panel.frame.size.height
                return
            }
            // Fall through to centered if we don't have a usable origin yet.
            fallthrough
        case .centered:
            centerOnActiveScreen(panel)
        }
    }

    private func centerOnActiveScreen(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let originX = visible.midX - size.width / 2
        let topY = visible.maxY - visible.height / 3
        anchoredTopY = topY
        panel.setFrameOrigin(NSPoint(x: originX, y: topY - size.height))
    }

    /// Verifies the remembered origin is still on some currently-attached
    /// screen — guards against the user dragging the panel onto an external
    /// display that's since been unplugged.
    private func isOnScreen(_ point: CGPoint) -> Bool {
        NSScreen.screens.contains { $0.frame.insetBy(dx: -20, dy: -20).contains(point) }
    }

    /// When the panel's content height changes, keep the top edge pinned so the
    /// input row doesn't visually jump as the response area grows.
    private func anchorTopEdge(_ panel: NSPanel) {
        guard !isAnchoring else { return }
        guard let topY = anchoredTopY else { return }
        var frame = panel.frame
        let newOriginY = topY - frame.size.height
        if abs(newOriginY - frame.origin.y) > 0.5 {
            isAnchoring = true
            frame.origin.y = newOriginY
            panel.setFrame(frame, display: true, animate: false)
            isAnchoring = false
        }
    }
}
