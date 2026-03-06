---
title: "设计方案：Batch ASR 直调 + Strategy 架构重构"
date: 2026-03-06
status: draft
audience: ai
tags: [design, refactor, asr]
---

# 设计方案：Batch ASR 直调 + Strategy 架构重构

> 文档日期：2026-03-06
> 状态：DRAFT
> 前置文档：`docs/design/2026-03-05-migrate-qwen3-realtime.md`

---

## 背景

当前 SpeakLow 硬编码使用流式 ASR（qwen3-asr-flash-realtime via Bridge WebSocket），所有请求都经过 Go bridge 中转。用户希望改为默认使用 qwen3-asr-flash 同步 API 直接从 Swift 调用 DashScope，不启动 Bridge。流式模式和 Bridge 代码保留但默认关闭。

---

## 改动概览

```
默认模式: Batch（Swift 直调 DashScope REST API，录完后一次性识别）
可选模式: Streaming（启用 Bridge，走 WebSocket 流式转写，边说边显示实时预览面板）
Bridge:   默认不启动，仅在用户开启 Streaming 模式时启动
切换:     运行时可在设置中随时切换，切换即时生效（Bridge 自动启停）
```

### 两种模式的用户体验差异

| | Batch（默认） | Streaming |
|---|---|---|
| **录音时 overlay** | 只显示波形动画 | 显示波形 + 实时文字预览面板 |
| **松开热键后** | "识别中..." → 文字插入 | 直接插入（已有流式结果） |
| **延迟感知** | 松开后等 0.7-1.4s | 边说边看到文字，松开即完成 |
| **Bridge 进程** | 不需要 | 需要运行 |
| **LLM Refine** | Swift 直调 DashScope | Swift 直调 DashScope（统一） |

---

## 架构设计：Strategy 模式

AppState 不应散布 `if mode == .batch / .streaming` 分支。采用 Strategy 模式，将模式差异封装在策略对象内部：

```
┌─────────────┐      ┌──────────────────────┐
│  AppState   │─────▶│ TranscriptionStrategy │  (protocol)
│             │      ├──────────────────────┤
│ hotkey down │      │ prepare()            │  录音前准备（Bridge 健康检查等）
│ hotkey up   │      │ begin(recorder)      │  开始录音（是否挂 streaming 回调）
│             │      │ finish(recorder)     │  停止录音 → 返回转写文本
│             │      │ needsBridge: Bool    │  是否需要 Bridge 进程
│             │      └──────────────────────┘
│             │               ▲        ▲
│             │      ┌────────┘        └────────┐
│             │      │                          │
│             │  ┌───┴──────────┐   ┌───────────┴──────┐
│             │  │BatchStrategy │   │StreamingStrategy │
│             │  │              │   │                  │
│             │  │ DashScope    │   │ Bridge WebSocket │
│             │  │ REST API     │   │ + 实时预览面板    │
│             │  └──────────────┘   └──────────────────┘
└─────────────┘
```

**AppState 只做：**
1. 持有 `strategy: TranscriptionStrategy`
2. hotkey down → `strategy.prepare()` + `strategy.begin(recorder)`
3. hotkey up → `text = strategy.finish(recorder)`
4. 拿到 text → LLM refine（独立于 strategy）→ TextInserter 插入
5. 切换模式 = 替换 strategy 实例

**AppState 不需要知道：** 是 batch 还是 streaming、是否需要 Bridge、overlay 是否显示预览面板。

---

## Part 1：架构重构 — Strategy 模式 + Batch 直调

### 1.1 新建 `DashScopeClient.swift` — Swift 端直调 DashScope

新文件 `speaklow-app/Sources/DashScopeClient.swift`。初始化时加载 API Key 和热词，缓存在内存中。

**Batch 转写 `transcribe(audioFileURL:)`：**
- 音频转 16kHz mono → base64 编码 → POST 到 `https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation`
- 请求体：`model: "qwen3-asr-flash"`, `input.messages` 含 system（热词 corpus text）+ user（audio data URI）, `parameters.asr_options.language_hints: ["zh", "en"]`
- 认证：`Authorization: Bearer {apiKey}`
- 解析响应：`output.choices[0].message.content[0].text`
- API Key：复用 `EnvLoader.loadDashScopeAPIKey()`，init 时加载
- 超时：30 秒

**LLM Refine `refine(text:style:)`：**
- POST 到 `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions`
- `model: "qwen-flash"`, `temperature: 0.2`, `max_tokens: 500`
- system message = preamble + prompt + style rule
- user message = `<transcription>\n{text}\n</transcription>`
- 长度卫士：输出 rune 数 > 输入 3 倍则回退原文
- Prompt 文件加载：init 时从 bundle Resources 加载 `refine_preamble.txt`、`refine_prompt.txt`、`refine_styles/*.txt`，缓存在内存
- 超时：8 秒，失败静默返回原文

**热词加载（init 时执行）：**
- 读 bundle 中 `Resources/hotwords.txt`
- 按行读取，跳过空行和 `#` 注释，取第 1 列（tab 分隔），第 5 列为音近提示
- 拼接为 corpus text：`"本次对话涉及 AI 开发技术，以下专有名词可能出现\n（括号内为中文音近说法，听到时请输出英文原文）：\n" + words.joined(separator: ", ")`
- 参考 `hotword.go:buildCorpusText()`

### 1.2 新建 `TranscriptionStrategy.swift` — Strategy 协议 + 两个实现

新文件 `speaklow-app/Sources/TranscriptionStrategy.swift`：

```swift
protocol TranscriptionStrategy {
    /// 是否需要 Bridge 进程
    var needsBridge: Bool { get }
    /// 录音前准备（如 Bridge 健康检查），返回 false 表示不可用
    func prepare(bridgeManager: ASRBridgeManager?) async -> Bool
    /// 开始录音，设置必要的回调
    func begin(recorder: AudioRecorder, overlay: RecordingOverlayManager)
    /// 停止录音并返回转写文本（异步）
    func finish(recorder: AudioRecorder, overlay: RecordingOverlayManager) async -> String?
}
```

**BatchStrategy：**
- `needsBridge = false`
- `prepare()` → 直接返回 true（不需要 Bridge）
- `begin()` → 只启动录音，overlay 只显示波形
- `finish()` → 停止录音 → 拿到 WAV → `DashScopeClient.transcribe()` → 返回文字

**StreamingStrategy：**
- `needsBridge = true`
- `prepare()` → Bridge 健康检查 + 自动重启（复用现有 `beginRecording()` 中的逻辑）
- `begin()` → 初始化 StreamingTranscriptionService + 启动录音 + 挂 audio chunk 回调 + overlay 显示实时预览面板
- `finish()` → 停止流式转写 → 等待最终结果 → 返回文字（复用现有 `streamingDidFinish()` 逻辑）

### 1.3 修改 `AppState.swift` — 用 Strategy 替代硬编码分支

**新增：**
- `@Published var asrMode: ASRMode`（UserDefaults key `asr_mode`，默认 `"batch"`）
- `private var strategy: TranscriptionStrategy`（根据 asrMode 创建）
- `private let dashScopeClient = DashScopeClient()`（单例，供 BatchStrategy 和 Refine 使用）

**asrMode didSet：**
- 替换 strategy 实例
- 如果新 strategy `needsBridge` → 启动 Bridge；否则停止 Bridge

**简化 `beginRecording()`：**
```swift
func beginRecording() {
    Task {
        let ready = await strategy.prepare(bridgeManager: bridgeManager)
        guard ready else { /* 显示错误 */ return }
        await MainActor.run {
            strategy.begin(recorder: audioRecorder, overlay: overlayManager)
        }
    }
}
```

**简化 `handleHotkeyUp()`：**
```swift
func handleHotkeyUp() {
    Task {
        guard let text = await strategy.finish(recorder: audioRecorder, overlay: overlayManager) else { return }
        // LLM Refine（独立于 strategy）
        let finalText = llmRefineEnabled
            ? await dashScopeClient.refine(text: text, style: refineStyle)
            : text
        await MainActor.run { TextInserter.insert(finalText) }
    }
}
```

**删除/简化的现有代码：**
- `_beginRecordingAfterHealthCheck()` 中的 streaming 初始化 → 移入 StreamingStrategy
- `stopAndTranscribe()` 中的 batch 转写 → 移入 BatchStrategy
- `stopStreamingRecording()` 中的流式结束 → 移入 StreamingStrategy
- `streamingDidFinish()` 中的结果合并 → 移入 StreamingStrategy

### 1.4 修改 `AppDelegate.swift` — Bridge 条件启动 + 权限前置

**Bridge 条件启动：**
```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    appState.bridgeManager = asrBridgeManager
    if appState.asrMode == .streaming {
        try asrBridgeManager.start()
    }
    // ...
}
```

**权限前置请求：** 在 `completeSetup()` 中立即请求：
```swift
func completeSetup() {
    // ... 现有逻辑 ...
    requestPermissionsUpfront()
}

private func requestPermissionsUpfront() {
    // 1. 麦克风权限（首次会弹系统对话框）
    AVCaptureDevice.requestAccess(for: .audio) { granted in
        viLog("Microphone permission: \(granted)")
    }
    // 2. Accessibility 权限检查（只能引导，不能自动授权）
    if !AXIsProcessTrusted() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
```

### 1.5 修改 `SettingsView.swift` — 模式选择 UI

在 "AI 文字优化" section 之前添加：

```swift
Section("识别模式") {
    Picker("模式", selection: $appState.asrMode) {
        Text("标准").tag(ASRMode.batch)
        Text("实时预览").tag(ASRMode.streaming)
    }
    .pickerStyle(.segmented)
    Text("标准：录完后一次性识别 ｜ 实时预览：边说边显示（需启动后台服务）")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

### 1.6 修改 `TextRefineService.swift` — 改为调用 DashScopeClient

`TextRefineService.refine()` 内部改为调用 `DashScopeClient.shared.refine()`，去掉对 Bridge `/v1/refine` 的 HTTP 调用。保持原有的静默降级行为。

---

## Part 2：Bridge 鲁棒性增强

当前问题：Bridge 崩溃后 `terminationHandler` 只清空引用，不自动重启；没有定时健康检查；Bridge 在两次录音之间崩溃时下次录音才发现。

### 2.1 修改 `ASRBridgeManager.swift` — 崩溃自动重启

**改进 `terminationHandler`：** 区分主动 stop 和崩溃，崩溃时自动重启：
```swift
proc.terminationHandler = { [weak self] process in
    guard let self else { return }
    let wasStopped = self.isStopping  // 新增 flag，stop() 时设为 true
    self.process = nil
    if !wasStopped {
        viLog("Bridge crashed (exit \(process.terminationStatus)), auto-restarting...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            try? self.start()
        }
    }
}
```

### 2.2 修改 `ASRBridgeManager.swift` — 定时健康检查

**新增 `startHealthMonitor()` / `stopHealthMonitor()`：**
- 每 30 秒 `/health` 轮询
- 连续 2 次失败 → 自动 restart
- 仅在 streaming 模式激活时运行
- 模式切换到 batch 时自动停止

---

## 不需要修改的文件

- `StreamingTranscriptionService.swift` — 保留，StreamingStrategy 使用
- `TranscriptionService.swift` — 保留，StreamingStrategy 内的 sync fallback 可能用到
- `asr-bridge/*` — Go 代码全部不动

---

## 关键文件清单

| 文件 | Part | 操作 |
|------|------|------|
| `Sources/DashScopeClient.swift` | 1 | **新建** — 直调 DashScope 的 ASR + Refine + 热词加载 |
| `Sources/TranscriptionStrategy.swift` | 1 | **新建** — Strategy 协议 + BatchStrategy + StreamingStrategy |
| `Sources/AppState.swift` | 1 | **修改** — 用 strategy 替代硬编码分支，新增 asrMode |
| `Sources/AppDelegate.swift` | 1 | **修改** — Bridge 条件启动 + 权限前置 |
| `Sources/SettingsView.swift` | 1 | **修改** — 模式选择 UI |
| `Sources/TextRefineService.swift` | 1 | **修改** — 改为调用 DashScopeClient |
| `Sources/ASRBridgeManager.swift` | 2 | **修改** — 崩溃自动重启 + 定时健康检查 |

## 复用清单

- `EnvLoader.loadDashScopeAPIKey()` — API Key 获取（`Sources/EnvLoader.swift`）
- `AudioRecorder` — 录音逻辑（`Sources/AudioRecorder.swift`）
- `TextInserter` — 文字插入（`Sources/TextInserter.swift`）
- `RecordingOverlayManager` — Overlay 管理（`Sources/RecordingOverlay.swift`）
- `StreamingTranscriptionService` — 流式转写（`Sources/StreamingTranscriptionService.swift`）
- `ASRBridgeManager` — Bridge 进程管理（`Sources/ASRBridgeManager.swift`）
- `TranscriptionService.convertTo16kMono()` — 音频格式转换，需提取为独立函数或在 DashScopeClient 中复现
- Bundle Resources 中的 prompt/hotword 文件 — 直接从 Swift 读取

## 附加任务：更新项目 CLAUDE.md 代码规范

在 `CLAUDE.md` 的 Conventions 部分添加设计范式规则：

- **行为差异用 Strategy 模式**：当同一流程存在多种实现方式（如 batch vs streaming），用 protocol + 具体实现封装差异，主流程代码通过 protocol 接口调用，不写 `if mode == X` 分支
- **配置驱动而非硬编码**：模式选择、功能开关等通过 UserDefaults 配置，代码根据配置创建对应的策略实例，而非在业务逻辑中硬编码模式判断

---

## 验证计划

1. **Batch 模式基本功能**：按住热键说话 → 松开 → 文字插入（无 Bridge 进程运行）
2. **LLM Refine**：开启 AI 优化 → 验证文字经过 LLM 润色
3. **热词生效**：说技术术语 → 验证识别准确（如 "Claude Code"、"WebSocket"）
4. **模式切换**：设置中切换到"实时预览" → Bridge 自动启动 → 流式识别正常工作
5. **切回 batch**：设置切回"标准" → Bridge 停止 → batch 识别正常
6. **Go bridge 测试**：`cd asr-bridge && go test ./...` 确保未破坏现有代码
7. **冷启动测试**：关闭 app → 重新打开 → 默认 batch 模式、无 Bridge 进程
8. **权限前置**：首次安装 → setup 完成 → 麦克风和 accessibility 权限已弹窗请求
9. **Bridge 崩溃恢复**：streaming 模式下手动 kill bridge → 观察 1 秒后自动重启 + 录音正常
