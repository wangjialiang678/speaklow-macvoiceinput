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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSettingsAPIKey),
            name: .showSettingsAPIKey,
            object: nil
        )

        // 仅在 streaming 模式且 API Key 可用时启动 Bridge
        // 缺 key 时跳过，避免 bridge 因无 key 而 log.Fatal 崩溃循环
        let hasAPIKey = EnvLoader.loadDashScopeAPIKey() != nil && !EnvLoader.loadDashScopeAPIKey()!.isEmpty
        if appState.asrMode == .streaming && hasAPIKey {
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
        } else if !hasAPIKey {
            viLog("API Key 未配置，跳过 Bridge 启动")
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

            // 启动时检测 API Key：未配置则自动打开密钥设置
            if let key = EnvLoader.loadDashScopeAPIKey(), !key.isEmpty {
                appState.overlayManager.showLaunchToast(hotkeyName: appState.selectedHotkey.displayName)
            } else {
                viLog("启动检测：API Key 未配置，自动打开密钥设置")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.showSettingsWindow(initialTab: "apiKey")
                }
            }
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

    @objc private func handleShowSettingsAPIKey() {
        showSettingsWindow(initialTab: "apiKey")
    }

    @objc private func handleReloadHotwords() {
        DashScopeClient.shared.reloadCorpusText()
        viLog("热词表已通过外部通知重载")
    }

    private func showSettingsWindow(initialTab: String? = nil) {
        if settingsWindow == nil {
            presentSettingsWindow(initialTab: initialTab)
        } else {
            settingsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            // 窗口已存在时（含最小化/隐藏），通知切换 tab
            if let tab = initialTab {
                NotificationCenter.default.post(name: .init("switchSettingsTab"), object: nil, userInfo: ["tab": tab])
            }
        }
    }

    private func presentSettingsWindow(initialTab: String? = nil) {
        let settingsView = SettingsView(initialTab: initialTab)
            .environmentObject(appState)
        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 620),
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

        // Setup 完成后检测 API Key：未配置则引导到密钥设置
        if let key = EnvLoader.loadDashScopeAPIKey(), !key.isEmpty {
            appState.overlayManager.showLaunchToast(hotkeyName: appState.selectedHotkey.displayName)
        } else {
            viLog("Setup 完成但 API Key 未配置，自动打开密钥设置")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showSettingsWindow(initialTab: "apiKey")
            }
        }
    }
}
