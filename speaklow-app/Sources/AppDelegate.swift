import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    var setupWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private let asrBridgeManager = ASRBridgeManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Give AppState a reference to bridge manager for auto-restart
        appState.bridgeManager = asrBridgeManager

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSetup),
            name: .showSetup,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSettings),
            name: .showSettings,
            object: nil
        )

        // 仅在 streaming 模式启动 Bridge，并做幂等保护避免重复启动
        if appState.asrMode == .streaming {
            if !asrBridgeManager.isRunning {
                do {
                    try asrBridgeManager.start()
                } catch {
                    viLog("Failed to start ASR Bridge: \(error)")
                }
            } else {
                viLog("ASR Bridge 已在运行，跳过重复启动")
            }

            if asrBridgeManager.isRunning {
                asrBridgeManager.startHealthMonitor()
            }
        } else {
            viLog("Batch mode: skipping ASR Bridge startup")
        }

        // 监听跨进程热词重载通知（CLI 触发）
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleReloadHotwords),
            name: .init("com.speaklow.reloadHotwords"),
            object: nil
        )

        if !appState.hasCompletedSetup {
            showSetupWindow()
        } else {
            appState.startHotkeyMonitoring()
            appState.startAccessibilityPolling()
            // 启动时主动检测权限状态：若二进制变更（重编译），引导用户重新授权
            appState.checkAccessibilityOnLaunch()
            // 启动提示：让用户知道 app 已就绪
            appState.overlayManager.showLaunchToast(hotkeyName: appState.selectedHotkey.displayName)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        asrBridgeManager.stop()
    }

    /// 用户点击 Dock/Launchpad 图标时，显示设置窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showSettingsWindow()
        }
        return true
    }

    @objc func handleShowSetup() {
        appState.hasCompletedSetup = false
        appState.stopAccessibilityPolling()
        showSetupWindow()
    }

    @objc private func handleShowSettings() {
        showSettingsWindow()
    }

    @objc private func handleReloadHotwords() {
        DashScopeClient.shared.reloadCorpusText()
        viLog("热词表已通过外部通知重载")
    }

    private func showSettingsWindow() {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if settingsWindow == nil {
            presentSettingsWindow()
        } else {
            settingsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func presentSettingsWindow() {
        let settingsView = SettingsView()
            .environmentObject(appState)
        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SpeakLow"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.settingsWindow = nil
        }
    }

    func showSetupWindow() {
        NSApp.setActivationPolicy(.regular)

        let setupView = SetupView(onComplete: { [weak self] in
            self?.completeSetup()
        })
        .environmentObject(appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "SpeakLow"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: setupView)
        window.minSize = NSSize(width: 520, height: 480)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        self.setupWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func completeSetup() {
        appState.hasCompletedSetup = true
        setupWindow?.close()
        setupWindow = nil
        // 保持 .regular 策略，Dock 始终显示图标
        appState.startHotkeyMonitoring()
        appState.startAccessibilityPolling()
    }
}
