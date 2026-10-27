import AppKit
import SwiftUI
import Combine
import UsageCore

final class FloatingPanel: NSPanel {
    private var dragOrigin: (mouse: NSPoint, window: NSPoint)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // AppKit otherwise constrains borderless panels to a screen's top edge.
    // Recovery is handled separately when a monitor is disconnected.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let contentView,
           containsDragArea(at: event.locationInWindow, in: contentView) {
            dragOrigin = (NSEvent.mouseLocation, frame.origin)
            NSCursor.closedHand.push()
            return
        }
        if event.type == .leftMouseDragged, let origin = dragOrigin {
            let mouse = NSEvent.mouseLocation
            setFrameOrigin(NSPoint(x: origin.window.x + mouse.x - origin.mouse.x,
                                   y: origin.window.y + mouse.y - origin.mouse.y))
            return
        }
        if event.type == .leftMouseUp, dragOrigin != nil {
            dragOrigin = nil
            NSCursor.pop()
            return
        }
        super.sendEvent(event)
    }

    private func containsDragArea(at point: NSPoint, in view: NSView) -> Bool {
        guard !view.isHiddenOrHasHiddenAncestor else { return false }
        if view is WindowDragArea.DragView, view.bounds.contains(view.convert(point, from: nil)) { return true }
        return view.subviews.contains { containsDragArea(at: point, in: $0) }
    }
}

@MainActor
final class WindowController: NSObject, NSWindowDelegate, NSPopoverDelegate, NSMenuItemValidation, AppAccessDriving {
    let state: AppState
    private(set) var panel: FloatingPanel!
    private let popover = NSPopover()
    private(set) var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var visibilityObserver: NSKeyValueObservation?
    private let injectedAccessDriver: (any AppAccessDriving)?
    private var sizeSubscription: AnyCancellable?
    private var screenObserver: Any?
    private var started = false
    private let interactive: Bool
    private let frameName = "CodexUsageMonitorWindow"

    init(state: AppState, interactive: Bool = true, accessDriver: (any AppAccessDriving)? = nil) {
        self.state = state
        self.interactive = interactive
        self.injectedAccessDriver = accessDriver
        super.init()
    }

    func start(background: Bool = false) {
        guard !started else { return }
        started = true
        if interactive { configureApplicationMenu() }
        configurePanel()
        configurePopover()
        sizeSubscription = state.objectWillChange
            .merge(with: state.loginItem.objectWillChange)
            .merge(with: state.usage.$rows.map { _ in () })
            .merge(with: state.usage.$errorMessage.map { _ in () })
            .merge(with: state.usage.$subscription.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.syncContentSizes() }
        if interactive || injectedAccessDriver != nil {
            state.applyAccess = { [weak self] requested in
                guard let self else {
                    return AccessTransitionResult(actual: AppAccess(menuBar: false, dock: false), error: "App access is unavailable. Reopen the app.")
                }
                let result = AccessTransition.apply(requested, using: self.injectedAccessDriver ?? self)
                if !result.actual.valid { self.state.openMain(); self.presentMain(activate: false) }
                return result
            }
            state.setAccess(menuBar: state.access.menuBar, dock: state.access.dock)
        }
        if interactive {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.recoverPosition() }
            }
        }
        state.launch(background: background)
        if !state.access.valid { state.openMain() }
        if state.presentation.mainVisible { presentMain(activate: !background) }
    }

    private func configureApplicationMenu() {
        let main = NSMenu()
        let application = NSMenuItem()
        let actions = NSMenu()
        addItem("Show Usage in Menu Bar", action: #selector(showPopover), key: "1", to: actions)
        addItem("Open Codex Usage Monitor", action: #selector(showFloating), key: "2", to: actions)
        addItem("Settings…", action: #selector(showSettings), key: ",", to: actions)
        addItem("Usage Analysis…", action: #selector(showHistory), key: "3", to: actions)
        actions.addItem(.separator())
        addItem("Quit Codex Usage Monitor", action: #selector(quit), key: "q", to: actions)
        application.submenu = actions
        main.addItem(application)
        NSApplication.shared.mainMenu = main
    }

    private func syncContentSizes() {
        guard started, let panel, let host = panel.contentView else { return }
        host.invalidateIntrinsicContentSize()
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        WindowContentSizing.fit(panel, to: host.fittingSize)
        recoverPosition()
        if let window = settingsWindow, let content = window.contentView {
            content.invalidateIntrinsicContentSize()
            content.layoutSubtreeIfNeeded()
            WindowContentSizing.fit(window, to: content.fittingSize)
        }
    }

    private func content(_ presentation: UsagePresentation) -> UsageView {
        UsageView(state: state, presentation: presentation,
                  changePresentation: { [weak self] in
                      if presentation == .floating { self?.hideMain() }
                      else { self?.showFloating() }
                  }, close: { [weak self] in
                      if presentation == .floating { self?.hideMain() }
                      else { self?.closeCard() }
                  }, settings: { [weak self] in self?.showSettings() }, history: { [weak self] in self?.showHistory() })
    }

    private func configurePanel() {
        let savedFrame = state.defaults.string(forKey: "NSWindow Frame \(frameName)")
            .flatMap(WindowPlacement.restoredFrame)
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 264),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Codex Usage Monitor"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content(.floating).fittingWindowContent { [weak self] size in
            guard let self, let panel = self.panel else { return }
            WindowContentSizing.fit(panel, to: size)
            self.recoverPosition()
        })
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        if let savedFrame {
            panel.setFrame(savedFrame, display: false)
        } else if interactive {
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: visible.maxX - 362, y: visible.maxY - 300))
            }
        }
        host.layoutSubtreeIfNeeded()
        WindowContentSizing.fit(panel, to: host.fittingSize)
        recoverPosition()
        // Do not save temporary layout positions over the user's frame during setup.
        // Explicit move/hide/quit saves retain the existing AppKit preference format.
        panel.delegate = self
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let host = NSHostingController(rootView: content(.menuBar).fittingWindowContent { [weak self] size in
            guard size.width > 0, size.height > 0 else { return }
            self?.popover.contentSize = size
        })
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.contentSize = host.view.fittingSize
    }

    var actualAccess: AppAccess {
        AppAccess(menuBar: statusItem?.isVisible == true && statusItem?.button != nil,
                  dock: NSApplication.shared.activationPolicy() == .regular)
    }

    func setDockVisible(_ visible: Bool) {
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        if NSApplication.shared.activationPolicy() != policy { _ = NSApplication.shared.setActivationPolicy(policy) }
        // Callers verify activationPolicy; the setter's return is not authoritative.
    }

    func installMenuBar() {
        if !actualAccess.menuBar {
            if statusItem != nil { removeMenuBar() }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem = item
            item.autosaveName = "CodexUsageMonitorStatusItem"
            item.behavior = .removalAllowed
            item.isVisible = true
            if let button = item.button {
                let image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Codex usage")
                image?.isTemplate = true
                button.image = image
                button.toolTip = "Codex usage — click to view, right-click for options"
                button.setAccessibilityLabel("Codex usage menu bar")
                button.target = self
                button.action = #selector(statusClicked)
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            visibilityObserver = item.observe(\.isVisible, options: [.new]) { [weak self] item, _ in
                let visible = item.isVisible
                Task { @MainActor in
                    guard let self, self.started, !visible, self.state.access.menuBar else { return }
                    if self.state.statusItemRemoved() { self.presentMain(activate: true) }
                }
            }
            if !actualAccess.menuBar { removeMenuBar() }
        }
    }

    func removeMenuBar() {
        closeCard()
        visibilityObserver?.invalidate()
        visibilityObserver = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    func reopen() { showFloating() }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() }
        else if popover.isShown { closeCard() }
        else { showPopover() }
    }

    @objc func showPopover() {
        guard state.access.menuBar else { return }
        if !interactive { state.showCard(); return }
        guard let button = statusItem?.button else { return }
        state.showCard()
        // Opening a card never tucks the main window or changes the saved presentation.
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closeCard() {
        state.closeCard()
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) { state.closeCard() }

    @objc func showFloating() {
        closeCard()
        state.openMain()
        presentMain(activate: true)
    }

    private func presentMain(activate: Bool) {
        recoverPosition()
        guard interactive else { return }
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    @objc func hideMain() {
        guard state.access.valid else { state.openMain(); presentMain(activate: false); return }
        closeCard()
        state.hideMain()
        if interactive { panel.saveFrame(usingName: frameName) }
        panel.orderOut(nil)
    }

    @objc func showSettings() {
        closeCard()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 230),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Codex Usage Monitor Settings"
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: SettingsView(state: state).fittingWindowContent { [weak window] size in
                if let window { WindowContentSizing.fit(window, to: size) }
            })
            host.sizingOptions = [.intrinsicContentSize]
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            WindowContentSizing.fit(window, to: host.fittingSize)
            window.center()
            settingsWindow = window
        }
        guard interactive else { return }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showHistory() {
        closeCard()
        if historyWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 620),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Codex Usage Analysis"
            window.delegate = self
            window.contentMinSize = NSSize(width: 760, height: 500)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: HistoryView(state: state))
            window.center()
            historyWindow = window
        }
        guard interactive else { return }
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
        state.history.setAnalysisVisible(true)
    }

    private func recoverPosition() {
        let recovered = WindowPlacement.recover(panel.frame, on: NSScreen.screens.map(\.visibleFrame))
        if recovered != panel.frame { panel.setFrame(recovered, display: panel.isVisible) }
    }

    func windowDidMove(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        if interactive { panel.saveFrame(usingName: frameName) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === historyWindow { state.history.setAnalysisVisible(false); return true }
        hideMain()
        return false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        if notification.object as? NSWindow === historyWindow { state.history.setAnalysisVisible(false) }
    }
    func windowDidDeminiaturize(_ notification: Notification) {
        if notification.object as? NSWindow === historyWindow { state.history.setAnalysisVisible(true) }
    }

    private func showMenu() {
        closeCard()
        guard let statusItem else { return }
        let menu = NSMenu()
        addItem("Open Codex Usage Monitor", action: #selector(showFloating), to: menu)
        addItem("Settings…", action: #selector(showSettings), to: menu)
        addItem("Usage Analysis…", action: #selector(showHistory), to: menu)
        if panel.isVisible { addItem("Hide Floating Window", action: #selector(hideMain), to: menu) }
        menu.addItem(.separator())
        addItem("Refresh Usage", action: #selector(refresh), key: "r", to: menu)
        addItem("Quit Codex Usage Monitor", action: #selector(quit), key: "q", to: menu)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func addItem(_ title: String, action: Selector, key: String = "", to menu: NSMenu) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        menu.addItem(entry)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(showPopover) || state.access.menuBar
    }

    @objc private func refresh() { state.usage.refresh() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    func stop() {
        guard started else { return }
        started = false
        if interactive || injectedAccessDriver != nil { state.applyAccess = nil }
        sizeSubscription?.cancel()
        sizeSubscription = nil
        visibilityObserver?.invalidate()
        visibilityObserver = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if interactive { panel.saveFrame(usingName: frameName) }
        closeCard()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        panel.orderOut(nil)
        settingsWindow?.orderOut(nil)
        historyWindow?.orderOut(nil)
        state.history.setAnalysisVisible(false)
    }
}
