import SwiftUI
import AVFoundation
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("Push-to-Talk Key") {
                Picker("Hotkey", selection: $appState.selectedHotkey) {
                    ForEach(HotkeyOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                if appState.selectedHotkey == .fnKey {
                    Text("Tip: If Fn opens Emoji picker, go to System Settings > Keyboard and change \"Press fn key to\" to \"Do Nothing\".")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Microphone") {
                Picker("Input Device", selection: $appState.selectedMicrophoneID) {
                    Text("System Default").tag("default")
                    ForEach(appState.availableMicrophones) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .onAppear {
                    appState.refreshAvailableMicrophones()
                }
            }

            Section("Startup") {
                Toggle("Launch at Login", isOn: $appState.launchAtLogin)
                    .onAppear {
                        appState.refreshLaunchAtLoginStatus()
                    }
            }

            Section("AI 文字优化") {
                Toggle("启用 AI 优化", isOn: $appState.llmRefineEnabled)

                if appState.llmRefineEnabled {
                    Picker("优化模式", selection: $appState.llmRefineMode) {
                        ForEach(RefineMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("语音识别后由大模型自动优化文字，可能增加 1-3 秒延迟")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("ASR Bridge") {
                ASRBridgeStatusView()
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
        .padding()
    }
}

struct ASRBridgeStatusView: View {
    @State private var isHealthy: Bool? = nil
    @State private var isChecking = false

    var body: some View {
        HStack {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            Text(statusText)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Check") {
                Task { await checkHealth() }
            }
            .disabled(isChecking)
        }
        .task {
            await checkHealth()
        }
    }

    private var statusIcon: String {
        switch isHealthy {
        case .some(true): return "checkmark.circle.fill"
        case .some(false): return "xmark.circle.fill"
        case .none: return "circle"
        }
    }

    private var statusColor: Color {
        switch isHealthy {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .secondary
        }
    }

    private var statusText: String {
        if isChecking { return "Checking..." }
        switch isHealthy {
        case .some(true): return "ASR Bridge running (localhost:18089)"
        case .some(false): return "ASR Bridge not available"
        case .none: return "ASR Bridge status unknown"
        }
    }

    private func checkHealth() async {
        isChecking = true
        let service = TranscriptionService()
        isHealthy = await service.checkHealth()
        isChecking = false
    }
}
