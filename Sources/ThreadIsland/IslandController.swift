import AppKit
import Carbon
import SwiftUI
import ThreadIslandCore

@MainActor
final class IslandController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private struct Jump {
        let session: Session
        let pendingResult: CompletedTurn?
    }

    private let model = LibraryModel()
    private var statusItem: NSStatusItem?
    private var compact: IslandStrip?
    private let liveMonitor = LiveMonitor()
    private var screensAwake = true
    private var jumpError: NSPopover?
    private var switcher: IslandPanel?
    private var cycle = IslandCycle()
    private var queuedJump: Jump?
    private var jumpTask: Task<Void, Never>?
    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "ZooCove")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.toolTip = "ZooCove · ⌃⌥J 展开 · ⌃⌘1–9 直达 · ⌃⌘Tab 切换"
        self.statusItem = statusItem
        registerShortcuts()
        liveMonitor.onChange = { [weak self] update in
            guard let self else { return }
            let previous = model.islandSessions
            model.updateLive(update)
            if previous != model.islandSessions {
                placeCompact()
            }
        }
        model.onIslandChanged = { [weak self] in self?.placeCompact() }
        model.onInstancesChanged = { [weak self] instances in
            guard let self else { return }
            liveMonitor.start(instances, recovering: model.trackedTurns)
        }
        liveMonitor.start(model.activeInstances, recovering: model.trackedTurns)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(resyncLive),
                                                           name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateMotion),
                                                           name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                           object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screensDidSleep),
                                                           name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screensDidWake),
                                                           name: NSWorkspace.screensDidWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(avatarsChanged),
                                                           name: SessionAvatars.didChange, object: nil)
        placeCompact()
        if CommandLine.arguments.contains("--show") { show() }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        placeCompact()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        liveMonitor.stop()
        model.didClose()
        jumpTask?.cancel()
        for hotKey in hotKeys { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let switcher, notification.object as? NSWindow === switcher else { return }
        // A folder picker is owned by the same application.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.switcher, !window.isKeyWindow,
                  NSApp.modalWindow == nil, window.attachedSheet == nil else { return }
            if !NSApp.isActive { self.hide() }
        }
    }

    @objc private func toggle() {
        if let switcher, !switcher.closing { hide() } else { show() }
    }

    private func show() {
        if let switcher {
            if switcher.closing {
                switcher.closeRevision += 1
                switcher.closing = false
                switcher.ignoresMouseEvents = false
                reveal(switcher)
            }
            NSApp.activate()
            switcher.makeKeyAndOrderFront(nil)
            return
        }
        let panel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: ExpandedIslandLayout.bodyWidth,
                                                    height: model.panelHeight),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        panel.setAccessibilityLabel("ZooCove 会话切换器")
        switcher = panel
        jumpError?.close()
        model.didOpen()
        place(panel)
        compact?.setExpanded(true)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        compact?.orderOut(nil)
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, switcher === panel, !panel.closing else { return }
            reveal(panel)
        }
    }

    private func reveal(_ panel: IslandPanel) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.presentation.progress = 1
        } else {
            withAnimation(.timingCurve(0.18, 0.84, 0.24, 1, duration: 0.24)) {
                panel.presentation.progress = 1
            }
        }
        compact?.setExpanded(true)
    }

    private func hide() {
        guard let panel = switcher, !panel.closing else { return }
        panel.closing = true
        panel.closeRevision += 1
        let revision = panel.closeRevision
        compact?.setExpanded(false)
        if panel.presentation.progress == 0 || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finishHide(panel)
            return
        }
        withAnimation(.easeIn(duration: 0.18)) {
            panel.presentation.progress = 0
        } completion: { [weak self, weak panel] in
            guard let self, let panel, panel.closing, panel.closeRevision == revision else { return }
            finishHide(panel)
        }
    }

    private func finishHide(_ panel: IslandPanel) {
        guard switcher === panel else { return }
        switcher = nil
        panel.delegate = nil
        compact?.restoreBar()
        placeCompact()
        panel.orderOut(nil)
        panel.contentView = nil
        model.didClose()
    }

    private func place(_ panel: IslandPanel, geometry: IslandGeometry? = nil) {
        let mouse = NSEvent.mouseLocation
        guard let screen = notchScreen ?? NSScreen.screens.first(where: { $0.frame.contains(mouse) })
                ?? NSScreen.main else { return }
        let layout = ExpandedIslandLayout(screen: screen, geometry: geometry ??
                                IslandGeometry(screen: screen, count: model.islandSessions.count),
                                          bodyHeight: model.panelHeight)
        guard panel.presentation.layout != layout else { return }
        panel.presentation.layout = layout
        let root: IslandPanelContent
        if let existing = panel.contentView as? IslandPanelContent {
            root = existing
        } else {
            root = IslandPanelContent(view: ExpandedIsland(model: model, presentation: panel.presentation,
                                                           close: { [weak self] in self?.hide() },
                                                           resize: { [weak self, weak panel] in
                DispatchQueue.main.async {
                    guard let self, let panel, self.switcher === panel, !panel.closing else { return }
                    self.place(panel)
                }
            }))
            panel.contentView = root
        }
        panel.setFrame(layout.frame, display: true)
        if let bar = layout.bar {
            compact?.attachBar(to: root, frame: bar)
        } else {
            compact?.restoreBar()
        }
    }

    private var notchScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    @objc private func resyncLive() { liveMonitor.resync() }

    @objc private func updateMotion() { placeCompact() }

    @objc private func avatarsChanged() { model.reloadAvatars() }

    @objc private func screensDidSleep() {
        screensAwake = false
        compact?.stopMotion()
    }

    @objc private func screensDidWake() {
        screensAwake = true
        model.reloadAvatars()
    }

    private func placeCompact() {
        let sessions = model.islandSessions
        guard let screen = notchScreen,
              let geometry = IslandGeometry(screen: screen, count: sessions.count) else {
            compact?.restoreBar()
            compact?.orderOut(nil)
            if let switcher { place(switcher) }
            return
        }
        let strip = compact ?? IslandStrip()
        compact = strip
        let avatars = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, model.avatar(for: $0.session)) })
        strip.update(geometry: geometry, sessions: sessions,
                     avatars: avatars, motionEnabled: screensAwake,
                     owner: self,
                     expand: #selector(toggle), jump: #selector(jumpToSession(_:)))
        strip.setExpanded(switcher.map { !$0.closing } ?? false)
        if let switcher {
            place(switcher, geometry: geometry)
        } else if !strip.isVisible {
            strip.orderFrontRegardless()
        }
    }

    @objc private func jumpToSession(_ sender: SessionIslandButton) {
        cycle.selected(sender.item.id, in: compact?.leftToRight.map(\.item.id) ?? [])
        enqueueJump(to: sender.item.session)
    }

    private func enqueueJump(to session: Session) {
        jumpError?.close()
        queuedJump = Jump(session: session, pendingResult: model.pendingResult(for: session))
        guard jumpTask == nil else { return }
        jumpTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let request = queuedJump {
                queuedJump = nil
                do {
                    try await DesktopRouter.open(request.session)
                    model.markViewed(request.pendingResult)
                } catch {
                    if queuedJump == nil { showJumpError(error, for: request.session) }
                }
            }
            jumpTask = nil
        }
    }

    private func showJumpError(_ error: Error, for session: Session) {
        guard let sender = compact?.leftToRight.first(where: { $0.item.id == session.id }),
              sender.window?.isVisible == true else { return }
        let popup = NSPopover()
        popup.behavior = .transient
        popup.contentSize = NSSize(width: 260, height: 116)
        let view = VStack(alignment: .leading, spacing: 8) {
            Text(session.instance.name).font(.headline)
            Text(error.localizedDescription).font(.caption).fixedSize(horizontal: false, vertical: true)
            Button("复制恢复命令") { [weak self, weak popup] in
                self?.model.copyCommand(session)
                popup?.close()
            }
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        let controller = NSViewController()
        controller.view = NSHostingView(rootView: view)
        popup.contentViewController = controller
        jumpError = popup
        popup.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    private func configureMenu() {
        let menu = NSMenu()
        let application = NSMenuItem()
        application.submenu = NSMenu()
        application.submenu?.addItem(withTitle: "退出 ZooCove",
                                    action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(application)

        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let commands = NSMenu(title: "编辑")
        commands.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        commands.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        commands.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        commands.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = commands
        menu.addItem(edit)
        NSApp.mainMenu = menu
    }

    private static let shortcutSignature: OSType = 0x5448494c

    private func registerShortcuts() {
        let numberKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                          kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        let direct = numberKeys.enumerated().map { ($0.offset + 1, $0.element, controlKey | cmdKey, "⌃⌘\($0.offset + 1)") }
        let bindings = direct + [(10, kVK_Tab, controlKey | cmdKey, "⌃⌘Tab"),
                                 (11, kVK_ANSI_J, controlKey | optionKey, "⌃⌥J")]
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                         EventParamType(typeEventHotKeyID), nil,
                                         MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard read == noErr else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<IslandController>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated {
                guard key.signature == IslandController.shortcutSignature else { return OSStatus(eventNotHandledErr) }
                owner.performShortcut(key.id)
                return noErr
            }
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else {
            model.shortcutConflicts = bindings.map { $0.3 }
            return
        }
        for (id, code, modifiers, label) in bindings {
            let key = EventHotKeyID(signature: Self.shortcutSignature, id: UInt32(id))
            var reference: EventHotKeyRef?
            let registration = RegisterEventHotKey(UInt32(code), UInt32(modifiers), key,
                                                    GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reference)
            if registration == noErr, let reference { hotKeys.append(reference) }
            else { model.shortcutConflicts.append(label) }
        }
        if !model.shortcutConflicts.isEmpty {
            statusItem?.button?.toolTip = "ZooCove · 部分快捷键不可用，详见设置"
        }
    }

    private func performShortcut(_ number: UInt32) {
        if number == 11 { toggle(); return }
        guard let compact, compact.isBarVisible else { return }
        let buttons = compact.leftToRight
        let button: SessionIslandButton?
        if number == 10 {
            let next = cycle.next(in: buttons.map(\.item.id))
            button = buttons.first { $0.item.id == next }
        } else if (1...9).contains(number), buttons.indices.contains(Int(number) - 1) {
            button = buttons[Int(number) - 1]
        } else {
            button = nil
        }
        guard let button else { return }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { button.flashShortcut() }
        jumpToSession(button)
    }
}

private final class IslandPanel: NSPanel {
    let presentation = IslandPresentation()
    var closing = false
    var closeRevision = 0

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
