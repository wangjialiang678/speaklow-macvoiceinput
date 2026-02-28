# VoiceInput 技术设计文档

## 1. ASR Bridge（Go）

### 1.1 职责

轻量级 HTTP 服务，接收音频文件，通过 WebSocket 连接阿里云 DashScope FunASR 进行实时语音识别，返回文本结果。

### 1.2 API 设计

```
POST /v1/transcribe
Content-Type: multipart/form-data

字段:
  file: 音频文件 (WAV/M4A/MP3)
  model: (可选) FunASR 模型名，默认 paraformer-realtime-v2
  sample_rate: (可选) 采样率，默认 16000
  format: (可选) 音频格式，默认 wav

响应:
{
  "text": "识别出的文本",
  "duration_ms": 1234
}

错误响应:
{
  "error": "error message"
}
```

```
GET /health
响应: {"status": "ok"}
```

### 1.3 核心流程

```
收到 HTTP 请求
  → 解析 multipart 表单，获取音频文件
  → 建立 WebSocket 连接到 DashScope
  → 发送 run-task JSON（model, format, sample_rate）
  → 等待 task-started 事件
  → 分块发送音频数据（每块 3200 bytes）
  → 发送 finish-task JSON
  → 收集所有 result-generated 事件中的文本
  → 等待 task-finished 事件
  → 返回拼接后的完整文本
```

### 1.4 文件结构

```
asr-bridge/
  main.go           # 入口，HTTP 服务器
  transcribe.go     # FunASR WebSocket 转写逻辑
  env.go            # .env 文件加载
  go.mod
```

### 1.5 依赖

- `github.com/gorilla/websocket` - WebSocket 客户端
- `github.com/joho/godotenv` - .env 文件加载

### 1.6 配置

通过环境变量或 .env 文件：
- `DASHSCOPE_API_KEY` (必须) - 阿里云 API Key
- `ASR_BRIDGE_PORT` (可选) - 监听端口，默认 18089
- `ASR_MODEL` (可选) - FunASR 模型名

---

## 2. Voice Input App（Swift）

### 2.1 基于 FreeFlow 的修改清单

| 文件 | 操作 | 说明 |
|------|------|------|
| App.swift | 修改 | 改名 VoiceInput，更新 bundle ID |
| AppState.swift | 大改 | 移除 Groq/PostProcessing/Context，加入 AX 文字插入 |
| AppDelegate.swift | 修改 | 移除 UpdateManager，加入 Go 进程管理 |
| TranscriptionService.swift | 重写 | 改为调用本地 ASR Bridge |
| MenuBarView.swift | 修改 | 简化菜单项 |
| SettingsView.swift | 修改 | 移除 API key 输入、Prompt 配置 |
| SetupView.swift | 修改 | 简化为权限引导 |
| HotkeyManager.swift | 保留 | 不改 |
| AudioRecorder.swift | 保留 | 不改 |
| RecordingOverlay.swift | 保留 | 不改 |
| KeychainStorage.swift | 保留 | 用于存储配置 |
| Notification+VoiceToText.swift | 保留 | 不改 |
| PostProcessingService.swift | 删除 | 不需要 LLM 后处理 |
| AppContextService.swift | 删除 | 不需要上下文截图 |
| PipelineDebugContentView.swift | 删除 | 不需要调试面板 |
| PipelineDebugPanelView.swift | 删除 | 不需要调试面板 |
| PipelineHistoryItem.swift | 删除 | 不需要历史记录 |
| PipelineHistoryStore.swift | 删除 | 不需要历史记录 |
| UpdateManager.swift | 删除 | 不需要自动更新 |

### 2.2 智能文字插入

优先级：
1. **AX API 直接插入**：通过 AXUIElementSetAttributeValue 设置焦点元素的 kAXValueAttribute
2. **剪贴板 + Cmd+V**：如果 AX 失败，复制到剪贴板并模拟 Cmd+V
3. **仅复制**：如果粘贴也失败，通知用户文字已在剪贴板中

```swift
func insertText(_ text: String) {
    // 1. 尝试 AX API 直接插入
    if insertViaAccessibility(text) { return }

    // 2. 回退到剪贴板 + Cmd+V
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)

    if pasteViaCmdV() { return }

    // 3. 提示用户
    showNotification("文字已复制到剪贴板，请手动粘贴")
}
```

### 2.3 Go 进程生命周期

```swift
class ASRBridgeManager {
    private var process: Process?

    func start() {
        let bridgePath = Bundle.main.bundlePath + "/Contents/MacOS/asr-bridge"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bridgePath)
        process.environment = loadEnvFile()
        process.launch()
        self.process = process
        waitForHealth()  // 轮询 /health 直到就绪
    }

    func stop() {
        process?.terminate()
        process?.waitUntilExit()
    }
}
```

### 2.4 .env 文件搜索顺序

1. `~/.config/voiceinput/.env`
2. App Bundle 所在目录的 `.env`
3. 环境变量 `DASHSCOPE_API_KEY`

### 2.5 文件结构

```
voice-input-app/
  Sources/
    App.swift
    AppDelegate.swift
    AppState.swift
    ASRBridgeManager.swift      # 新增：Go 进程管理
    AudioRecorder.swift
    EnvLoader.swift             # 新增：.env 文件加载
    HotkeyManager.swift
    KeychainStorage.swift
    MenuBarView.swift
    Notification+VoiceToText.swift
    RecordingOverlay.swift
    SettingsView.swift
    SetupView.swift
    TextInserter.swift          # 新增：智能文字插入
    TranscriptionService.swift  # 重写：调用本地 ASR Bridge
  Resources/
    AppIcon-Source.png
  Info.plist
  VoiceInput.entitlements
  Makefile
```

---

## 3. 构建流程

### 3.1 Go 二进制

```bash
cd asr-bridge
GOOS=darwin GOARCH=arm64 go build -o asr-bridge-arm64 .
GOOS=darwin GOARCH=amd64 go build -o asr-bridge-amd64 .
lipo -create -output asr-bridge asr-bridge-arm64 asr-bridge-amd64
```

### 3.2 Swift 应用

```bash
cd voice-input-app
make all  # 编译 Swift + 打包 .app
# Makefile 会自动将 asr-bridge 二进制复制到 .app/Contents/MacOS/
```

### 3.3 最终产物

```
build/VoiceInput.app  # 可直接双击运行
```
