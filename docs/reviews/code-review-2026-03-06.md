# SpeakLow 代码审核报告

审查范围：`asr-bridge/*.go` 与 `speaklow-app/Sources/*.swift`（逐文件静态审查）
审查日期：2026-03-06

## 概要统计

- 审查文件数：24（Go 7 + Swift 17）
- 问题总数：32
- 严重级别分布：
  - `[P0-Critical]` 0
  - `[P1-Major]` 10
  - `[P2-Minor]` 16
  - `[P3-Nitpick]` 6

## Go Bridge (asr-bridge/)

### 文件: env.go

- `[P3-Nitpick]` [asr-bridge/env.go](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/env.go#L24) 忽略 `godotenv.Load` 错误，`.env` 格式错误时会静默失败，排查困难。

### 文件: hotword.go

- 未发现需整改问题。

### 文件: main.go

- `[P1-Major]` [main.go](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/main.go#L89)~[main.go](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/main.go#L91) `isAllowedOrigin` 采用字符串前缀匹配，`http://localhost.evil.com` 会被误判为可信来源，存在 CORS 绕过风险。
- `[P2-Minor]` [main.go](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/main.go#L45) 使用 `http.ListenAndServe` 默认服务器，未设置 `ReadHeaderTimeout/ReadTimeout/WriteTimeout`，抗慢连接能力弱。

### 文件: refine.go

- `[P2-Minor]` [refine.go](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/refine.go#L51) 与 [refine.go](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/refine.go#L123) 对入参和上游响应均未做大小限制，存在被超大请求/响应拖垮内存的风险。

### 文件: refine_test.go

- `[P2-Minor]` [refine_test.go](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/refine_test.go#L18)~[refine_test.go](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/refine_test.go#L133) 单元测试直接调用线上 LLM，结果不稳定且有外部依赖/费用，容易造成 CI 偶发失败。

### 文件: stream.go

- `[P1-Major]` [stream.go](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/stream.go#L279)~[stream.go](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/stream.go#L292) 记录 DashScope 原始事件（含识别文本），有用户语音内容泄露到日志的隐私风险。
- `[P2-Minor]` [stream.go](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/stream.go#L60) 与 [stream.go](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/stream.go#L135) 客户端 `start.model` 被忽略，模型被硬编码，配置项与协议不一致，增加维护成本。
- `[P2-Minor]` [stream.go](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/stream.go#L227)~[stream.go](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/stream.go#L239) 对非法 JSON/base64 仅 `continue`，未返回错误事件，客户端很难定位流式失败原因。

### 文件: transcribe_sync.go

- `[P1-Major]` [transcribe_sync.go](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/transcribe_sync.go#L35) 与 [transcribe_sync.go](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/transcribe_sync.go#L57)~[transcribe_sync.go](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/transcribe_sync.go#L59) 把整段音频读入内存并再做 base64，峰值内存会显著放大。
- `[P2-Minor]` [transcribe_sync.go](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/transcribe_sync.go#L23) 使用 `ParseMultipartForm` 后未 `RemoveAll()`，大文件场景会残留临时文件。
- `[P2-Minor]` [transcribe_sync.go](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/transcribe_sync.go#L105) 下游请求未绑定上游 `r.Context()`，客户端断开后仍可能继续占用外部 API 资源。

## Swift App (speaklow-app/Sources/)

### 文件: ASRBridgeManager.swift

- `[P1-Major]` [ASRBridgeManager.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/ASRBridgeManager.swift#L23)~[ASRBridgeManager.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/ASRBridgeManager.swift#L24) `start()` 在二进制缺失时直接 `return`，但函数签名是 `throws`，调用方会误判“启动成功”。
- `[P2-Minor]` [ASRBridgeManager.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/ASRBridgeManager.swift#L74)~[ASRBridgeManager.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/ASRBridgeManager.swift#L77) `stop()` 同步 `waitUntilExit()`，在主线程调用时可能卡住 UI/退出流程。

### 文件: App.swift

- 未发现需整改问题。

### 文件: AppDelegate.swift

- `[P2-Minor]` [AppDelegate.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/AppDelegate.swift#L92)~[AppDelegate.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/AppDelegate.swift#L99) block 形式 `addObserver` 返回 token 未保存/移除，窗口多次创建关闭时会累积观察者。

### 文件: AppState.swift

- `[P1-Major]` [AppState.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/AppState.swift#L27) 使用 `@unchecked Sendable`，但类内存在大量可变共享状态与跨线程读写（如 [AppState.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/AppState.swift#L438)），掩盖并发安全问题。
- `[P2-Minor]` [AppState.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/AppState.swift#L13)~[AppState.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/AppState.swift#L23) `viLog` 多线程无锁写同一日志文件，可能出现日志交织/丢写。
- `[P1-Major]` [AppState.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/AppState.swift#L270)~[AppState.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/AppState.swift#L315) 首次申请麦克风权限（`.notDetermined`）路径会先把 `isRecording` 置回 `false`，回调里直接 `beginRecording()`，状态机可能出现“实际录音中但状态为 false”。
- `[P1-Major]` [AppState.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/AppState.swift#L420)~[AppState.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/AppState.swift#L435) 静音超时分支只更新 UI，不清理 `streamingService/isStreaming`，会留下悬挂流式会话。
- `[P2-Minor]` [AppState.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/AppState.swift#L951) `withTimeout` 使用 `group.next()!` 强制解包，极端取消时存在崩溃风险。
- `[P3-Nitpick]` [AppState.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/AppState.swift#L724)~[AppState.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/AppState.swift#L729) `showNotification` 未被调用且基于已废弃的 `NSUserNotification`。

### 文件: AudioRecorder.swift

- `[P2-Minor]` [AudioRecorder.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/AudioRecorder.swift#L198) `inputNode.audioUnit!` 强制解包，音频节点异常时会直接崩溃。
- `[P1-Major]` [AudioRecorder.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/AudioRecorder.swift#L365) 在后台线程更新 `@Published isRecording`（调用链见 [AppState.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/AppState.swift#L438)），有主线程发布违规与竞态风险。

### 文件: EnvLoader.swift

- 未发现需整改问题。

### 文件: HotkeyManager.swift

- 未发现需整改问题。

### 文件: KeychainStorage.swift

- `[P3-Nitpick]` [KeychainStorage.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/KeychainStorage.swift#L4) 该存储模块在项目中无引用（全局搜索仅定义处），属于死代码；且命名为 `Keychain` 实际为明文文件存储，易误导维护者。

### 文件: MenuBarView.swift

- 未发现需整改问题。

### 文件: Notification+VoiceToText.swift

- `[P3-Nitpick]` [Notification+VoiceToText.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/Notification+VoiceToText.swift#L1)~[Notification+VoiceToText.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/Notification+VoiceToText.swift#L5) 仅注释无实现，建议删除或补全，避免噪音文件。

### 文件: RecordingOverlay.swift

- `[P2-Minor]` [RecordingOverlay.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/RecordingOverlay.swift#L356)~[RecordingOverlay.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/RecordingOverlay.swift#L366) 错误浮层自动关闭使用裸 `asyncAfter`，未区分“旧任务/新面板”，可能导致新错误提示被旧定时任务提前关闭。

### 文件: SettingsView.swift

- 未发现需整改问题。

### 文件: SetupView.swift

- 未发现需整改问题。

### 文件: StreamingTranscriptionService.swift

- `[P1-Major]` [StreamingTranscriptionService.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/StreamingTranscriptionService.swift#L76)~[StreamingTranscriptionService.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/StreamingTranscriptionService.swift#L77)、[StreamingTranscriptionService.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/StreamingTranscriptionService.swift#L155) 与 [StreamingTranscriptionService.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/StreamingTranscriptionService.swift#L178) 对 `isConnected/webSocketTask` 的跨线程访问未同步（音频线程发送 + WebSocket 回调修改），存在 race condition。
- `[P3-Nitpick]` [StreamingTranscriptionService.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/StreamingTranscriptionService.swift#L130) `if self.isConnected || !self.isConnected` 恒为真，控制流表达失真，后续维护容易引入逻辑错误。

### 文件: TextInserter.swift

- `[P2-Minor]` [TextInserter.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/TextInserter.swift#L68)、[TextInserter.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/TextInserter.swift#L76)、[TextInserter.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/TextInserter.swift#L185) 使用 `Thread.sleep` 阻塞调用线程（常见为主线程），会造成 UI 卡顿。
- `[P2-Minor]` [TextInserter.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/TextInserter.swift#L58)~[TextInserter.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/TextInserter.swift#L93) 延迟恢复剪贴板会覆盖用户在这 1 秒内的新复制内容。

### 文件: TextRefineService.swift

- `[P3-Nitpick]` [TextRefineService.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/TextRefineService.swift#L35) `URL(string: refineURL)!` 强制解包，虽然当前常量可用，但建议改为安全失败路径。

### 文件: TranscriptionService.swift

- `[P1-Major]` [TranscriptionService.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/TranscriptionService.swift#L55) 使用 `/v1/transcribe`，但 bridge 实际暴露的是 `/v1/transcribe-sync`（见 [main.go](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/asr-bridge/main.go#L37)），导致批处理转写回退链路不可用。
- `[P2-Minor]` [TranscriptionService.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/TranscriptionService.swift#L59)~[TranscriptionService.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/TranscriptionService.swift#L65) 转码临时文件只在成功路径删除（[TranscriptionService.swift](/Users/michael/projects/自用小工具/speaklow-macvoiceinput/speaklow-app/Sources/TranscriptionService.swift#L121)），失败时会残留。

## 总结与建议

- 先处理高优先级链路故障：
  - `TranscriptionService` 端点不一致（批处理回退失效）。
  - `AppState` 的静音超时未清理流式状态。
  - `StreamingTranscriptionService` 与 `AppState/AudioRecorder` 的并发状态访问。
- 再处理安全与可运维问题：
  - CORS origin 校验方式（前缀匹配）与流式日志隐私暴露。
  - Go HTTP 服务超时与请求体大小限制。
- 最后清理可维护性项：
  - 死代码文件（`Notification+VoiceToText.swift`、未引用的 `AppSettingsStorage`）。
  - 强制解包与阻塞式 `Thread.sleep` 等可预防风险。
