//
//  TextreamApp.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import SwiftUI
import OSLog
import Carbon

@MainActor
private func openTAAssistant() {
    let service = TextreamService.shared
    service.hideMainWindowImmediately()
    NSApp.activate(ignoringOtherApps: true)
    let assistant = TAAssistantWindow.shared
    let lecturePrompter = LecturePrompterBridge.shared
    lecturePrompter.attach(session: assistant.lectureSession) { [weak assistant] in
        assistant?.resumeLecture()
    }
    assistant.show(lecturePrompter: lecturePrompter,
                   lectureReference: { lecturePrompter.lectureReferenceExcerpt() }) { text in
        // Classic scrolling keeps the meeting's system-audio recognizer active.
        let settings = NotchSettings.shared
        settings.listeningMode = .classic
        settings.overlayMode = .pinned
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            settings.notchDisplayMode = .fixedDisplay
            settings.pinnedScreenID = screen.displayID
        }
        service.hideMainWindowImmediately()
        service.overlayController.show(text: text, hasNextPage: false) {}
    }
}

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
    static let openAbout = Notification.Name("openAbout")
    static let startPrompter = Notification.Name("startPrompter")
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var assistantHotKey: EventHotKeyRef?
    private var assistantKeyHandler: EventHandlerRef?
    private let lifecycleLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.liyitingglitch.textream.ta",
        category: "AppLifecycle"
    )

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        let launchedByURL: Bool
        if let event = NSAppleEventManager.shared().currentAppleEvent {
            launchedByURL = event.eventClass == kInternetEventClass
        } else {
            launchedByURL = false
        }
        if launchedByURL {
            TextreamService.shared.launchedExternally = true
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = TextreamService.shared
        NSUpdateDynamicServices()
        registerAssistantHotKey()

        if TextreamService.shared.launchedExternally {
            TextreamService.shared.hideMainWindow()
        }

        // TA builds are installed explicitly; never offer an upstream official update.

        // Start browser server if enabled
        TextreamService.shared.updateBrowserServer()

        // Start director server if enabled
        TextreamService.shared.updateDirectorServer()

        // Set window delegate to intercept close, disable tabs and fullscreen
        DispatchQueue.main.async {
            for window in NSApp.windows where !(window is NSPanel) {
                window.delegate = self
                window.tabbingMode = .disallowed
                window.collectionBehavior.remove(.fullScreenPrimary)
                window.collectionBehavior.insert(.fullScreenNone)
            }
            self.removeUnwantedMenus()
        }
    }

    private func removeUnwantedMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }
        // Remove View and Window menus (keep Edit for copy/paste)
        let menusToRemove = ["View", "Window"]
        for title in menusToRemove {
            if let index = mainMenu.items.firstIndex(where: { $0.title == title }) {
                mainMenu.removeItem(at: index)
            }
        }
    }

    private func registerAssistantHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var keyID = EventHotKeyID()
            guard let event,
                  GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                    EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &keyID) == noErr,
                  keyID.signature == 0x54414153, keyID.id == 1 else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { openTAAssistant() }
            return noErr
        }, 1, &eventType, nil, &assistantKeyHandler)
        guard handlerStatus == noErr else {
            lifecycleLogger.error("Unable to install TA shortcut handler: \(handlerStatus)")
            return
        }
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(controlKey | optionKey | cmdKey),
                                         EventHotKeyID(signature: 0x54414153, id: 1),
                                         GetApplicationEventTarget(), 0, &assistantHotKey)
        if status != noErr {
            lifecycleLogger.error("Control-Option-Command-A is unavailable: \(status)")
        } else {
            lifecycleLogger.notice("Registered global TA shortcut Control-Option-Command-A")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let assistantHotKey { UnregisterEventHotKey(assistantHotKey) }
        if let assistantKeyHandler { RemoveEventHandler(assistantKeyHandler) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if TextreamService.shared.hasUnsavedChanges {
            guard TextreamService.shared.confirmDiscardIfNeeded() else { return false }
        }
        NSApp.terminate(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard
            TextreamService.shared.overlayController.isShowing,
            let event = NSAppleEventManager.shared().currentAppleEvent,
            event.eventClass == kCoreEventClass,
            event.eventID == kAEQuitApplication,
            event.paramDescriptor(forKeyword: kAEQuitReason) == nil
        else {
            return .terminateNow
        }

        let senderPID = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value ?? 0
        let runningApplication = NSRunningApplication(processIdentifier: pid_t(senderPID))
        let senderName = runningApplication?.localizedName ?? "unknown"
        let senderBundleIdentifier = runningApplication?.bundleIdentifier ?? "unknown"

        lifecycleLogger.warning(
            "Blocked external quit while teleprompter is active; senderPID=\(senderPID, privacy: .public) sender=\(senderName, privacy: .public) bundleIdentifier=\(senderBundleIdentifier, privacy: .public)"
        )
        return .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        if TextreamService.shared.launchedExternally {
            TextreamService.shared.launchedExternally = false
            NSApp.setActivationPolicy(.regular)
        }
        // A Dock click explicitly requests the editor, even if a TA panel is visible.
        for window in NSApp.windows where !(window is NSPanel) {
            window.makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.pathExtension == "textream" {
                TextreamService.shared.openFileAtURL(url)
                // Show the main window for file opens
                for window in NSApp.windows where !(window is NSPanel) {
                    window.makeKeyAndOrderFront(nil)
                }
                NSApp.activate(ignoringOtherApps: true)
            } else {
                let wasExternal = TextreamService.shared.launchedExternally
                TextreamService.shared.launchedExternally = true
                if !wasExternal {
                    NSApp.setActivationPolicy(.accessory)
                }
                TextreamService.shared.hideMainWindow()
                TextreamService.shared.handleURL(url)
            }
        }
    }
}

@main
struct TextreamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Textream TA") {
            ContentView()
                .onOpenURL { url in
                    if url.pathExtension == "textream" {
                        TextreamService.shared.openFileAtURL(url)
                    } else {
                        TextreamService.shared.handleURL(url)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        .commands {
            CommandMenu("TA Assistant") {
                Button("Open TA Assistant…") {
                    openTAAssistant()
                }
                .keyboardShortcut("a", modifiers: [.control, .option, .command])
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Textream TA") {
                    NotificationCenter.default.post(name: .openAbout, object: nil)
                }
                #if !APP_STORE
                Divider()
                Button("Download TA builds…") {
                    UpdateChecker.shared.showBuildDownloads()
                }
                #endif
            }
            CommandGroup(after: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open File or Presentation…") {
                    TextreamService.shared.openFile()
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Save") {
                    TextreamService.shared.saveFile()
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Save As…") {
                    TextreamService.shared.saveFileAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Button("Start Prompter") {
                    NotificationCenter.default.post(name: .startPrompter, object: nil)
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
            CommandGroup(replacing: .windowArrangement) { }
            CommandGroup(replacing: .help) {
                Button("Textream TA Help") {
                    if let url = URL(string: "https://github.com/liyiting-glitch/textream-ta/blob/codex/lecture-interrupt-resume/TA_ASSISTANT.md") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
