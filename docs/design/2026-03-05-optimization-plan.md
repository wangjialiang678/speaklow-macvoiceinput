---
title: "SpeakLow 优化实施方案"
date: 2026-03-05
status: outdated
audience: ai
tags: [design, optimization]
---

# SpeakLow 优化实施方案

> 文档用途：供 Claude Code 进程直接参照实施。所有描述均基于 2026-03-05 实测数据和代码分析。
>
> 实施顺序：Phase 1 → Phase 2 → Phase 3 → Phase 4（见文末）

---

## 整体架构回顾

```
用户按热键
  ↓
AudioRecorder 捕获麦克风 (AVAudioEngine, 16kHz mono PCM)
  ↓
StreamingTranscriptionService (WebSocket → asr-bridge /v1/stream)
  ↓ 实时返回 partial/sentence_end
AppState (RecordingOverlay 实时预览)
  ↓ 松手
stopStreamingRecording() → streamingService.stop()
  ↓ bridge 返回 streamingDidFinish()
streamingDidFinish() → LLM refine → TextInserter
```

**关键文件**：

| 文件 | 职责 |
|------|------|
| `speaklow-app/Sources/AppState.swift` | 主流程编排，录音生命周期，streaming delegate |
| `speaklow-app/Sources/AudioRecorder.swift` | AVAudioEngine 录音，WAV 文件写入 |
| `speaklow-app/Sources/StreamingTranscriptionService.swift` | WebSocket 客户端 |
| `speaklow-app/Sources/TextInserter.swift` | 三层降级文字插入 |
| `speaklow-app/Sources/TextRefineService.swift` | LLM 润色调用 |
| `asr-bridge/main.go` | HTTP 路由注册，环境变量初始化 |
| `asr-bridge/transcribe.go` | 批量 ASR（paraformer，通过 realtime.Module） |
| `asr-bridge/hotword.go` | 热词表生命周期管理 |
| `asr-bridge/refine.go` | LLM 润色端点 |
| `speaklow-app/Resources/hotwords.txt` | 热词表文件 |

---

## Phase 1：Bug 修复 + 前置依赖

### Bug 1：Socket 关闭假错误（P0）

**文件**：`speaklow-app/Sources/AppState.swift`

**问题定位**：
- `streamingDidFinish()` 第 775 行已有 `guard isStreaming else { return }` 守卫，成功阻止了双触发。
- 但 `streamingDidFail()` 第 893 行没有对应守卫。
- 流程：`streamingDidFinish()` 将 `isStreaming = false` 并 disconnect，WebSocket 关闭后仍会触发 `streamingDidFail()`，导致日志出现 "falling back to batch mode"。

**修复位置**：`streamingDidFail()` 函数入口（第 893 行附近）

**修复方式**：在函数开头增加已完成检测标志。需新增实例变量 `private var streamingHasFinished = false`，在 `streamingDidFinish()` 中设为 `true`，在录音开始时重置为 `false`，在 `streamingDidFail()` 中作为 guard。

**具体改动**：

1. 在 `AppState` 的 streaming state 区域（第 78-85 行附近）新增：
   ```swift
   private var streamingHasFinished = false
   ```

2. 在 `_beginRecordingAfterHealthCheck()` 中 `self.committedSentences = []` 附近，重置标志：
   ```swift
   self.streamingHasFinished = false
   ```

3. 在 `streamingDidFinish()` 开头（`guard isStreaming else { return }` 之后）设置：
   ```swift
   streamingHasFinished = true
   ```

4. 在 `streamingDidFail()` 开头增加守卫：
   ```swift
   guard !streamingHasFinished else {
       viLog("Streaming: close callback after finish, ignoring")
       return
   }
   ```

**验收标准**：日志中不再出现 "Socket is not connected...falling back to batch mode"。

---

### Bug 2：热键双击残留（P1）

**文件**：`speaklow-app/Sources/AppState.swift`

**问题定位**：快速按放（同一秒内完成两次 down-up），第二次 `stopStreamingRecording()` 时录音时长 < 200ms，音频数据不足，触发 `funasr task failed`。

**修复位置**：`stopStreamingRecording()` 函数（第 470 行附近）

**修复方式**：在 `stopStreamingRecording()` 入口处检查录音时长，不足 200ms 则直接丢弃（调 `audioRecorder.cleanup()`，重置状态，不发 stop 给 bridge）。

需要记录录音开始时间。在 `_beginRecordingAfterHealthCheck()` 中 `audioRecorder.startRecording()` 成功回调处记录：

1. 新增实例变量：
   ```swift
   private var recordingStartTime: Date?
   ```

2. 在 `audioRecorder.onRecordingReady` 回调中记录（第 390 行附近）：
   ```swift
   self.recordingStartTime = Date()
   ```

3. 在 `stopStreamingRecording()` 入口添加最短时长检查：
   ```swift
   let elapsed = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 1.0
   if elapsed < 0.2 {
       viLog("stopStreamingRecording: 录音时长 \(Int(elapsed * 1000))ms < 200ms，丢弃")
       audioRecorder.cleanup()
       isRecording = false
       streamingService?.disconnect()
       streamingService = nil
       isStreaming = false
       overlayManager.dismiss()
       return
   }
   ```

**验收标准**：快速双击不触发 `funasr task failed`。

---

### Bug 3：短录音文本丢失（P1）

**文件**：`speaklow-app/Sources/AppState.swift`

**问题定位**：`streamingDidFinish()` 第 788 行用 `committedSentences.joined()` 作为最终文本。短录音（< 1 句）没有产生 `sentence_end` 事件，`committedSentences` 为空，即使 `lastPartialText` 有内容也被忽略，导致显示"未检测到语音"。

**修复位置**：`streamingDidFinish()` 第 788 行附近

**修复方式**：若 `committedSentences` 为空但 `lastPartialText` 非空，用 `lastPartialText` 作为兜底结果。

**具体改动**（替换第 788 行）：
```swift
var fullText = committedSentences.joined()
if fullText.isEmpty && !lastPartialText.isEmpty {
    viLog("Streaming: no committed sentences but has partial '\(lastPartialText.prefix(40))', using as final")
    fullText = lastPartialText
}
```

**验收标准**：短录音有 partial text 时不显示"未检测到语音"。

---

### 优化 0：修复 WAV 文件写入（P0，优化 1 的前置依赖）

**文件**：`speaklow-app/Sources/AudioRecorder.swift`

**问题定位**：当前 AudioRecorder 仅有 streaming 模式（`onStreamingAudioChunk` 回调），WAV 文件写入逻辑需要核查。优化 1 需要在松手后把完整录音 WAV 文件发给 `/v1/transcribe-sync`。

**调查方向**：
1. 检查 `startRecording()` 是否在引擎复用时跳过了 AVAudioFile 创建
2. 检查 PCM buffer 是否同步写入到文件（是否有未 flush 的情况）
3. 确认录音文件路径与 `stopRecording()` 返回的 URL 一致

**所需行为**：
- `startRecording()` 每次录音都创建新的临时 WAV 文件（16kHz, 16bit, mono）
- streaming audio chunk 同时写入文件 AND 通过回调发给 WebSocket
- `stopRecording()` 确保文件 flush 后返回有效 URL
- 录音 5s 以上的文件大小应 > 100KB

**如果当前未写文件**，需要在 `onStreamingAudioChunk` 回调中同步将 PCM 数据也写入临时 WAV 文件。具体实现参考：
```swift
// 在 startRecording() 中创建文件
let tempURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("speaklow_\(Date().timeIntervalSince1970).wav")
// AVAudioFile 以 16kHz 16bit mono WAV 格式写入
// 在 installTap block 中：rawBuffer 写文件 + sendChunk
```

**验收标准**：录音 5s 以上，对应 WAV 文件大小 > 100KB（16kHz/16bit/mono: 约 32KB/s）。

---

## Phase 2：核心优化

### 优化 1：qwen3-asr-flash 二次识别（P0）

**目标**：松手后用准确率更高、速度更快的 qwen3-asr-flash 做最终识别，流式结果作为 fallback。

**性能数据**（2026-03-05 实测）：

| 音频时长 | qwen3-asr-flash | paraformer-realtime-v2 | 速度比 |
|----------|----------------|----------------------|--------|
| 6.5s | 776ms | 1780ms | 2.3x |
| 15s | 964-1408ms | 2740-3314ms | 2.4-2.8x |
| 22.6s | 1158-1372ms | 5996ms | 4.4x |

#### 1.1 asr-bridge 侧：新增 `/v1/transcribe-sync` 端点

**新建文件**：`asr-bridge/transcribe_sync.go`

该文件实现调用 qwen3-asr-flash 的同步 REST API。

**qwen3-asr-flash API 规格**：
- 端点：`POST https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation`
- 认证：`Authorization: Bearer {DASHSCOPE_API_KEY}`
- 请求体（JSON）：
  ```json
  {
    "model": "qwen3-asr-flash",
    "input": {
      "messages": [
        {
          "role": "system",
          "content": [{"text": "Cursor, Claude Code, Copilot, ..."}]
        },
        {
          "role": "user",
          "content": [{"audio": "data:audio/wav;base64,<base64音频>"}]
        }
      ]
    },
    "parameters": {
      "asr_options": {
        "language_hints": ["zh", "en"]
      }
    }
  }
  ```
- 热词通过 system message 的 `content[0].text` 传入，逗号分隔词表，上限 10000 tokens
- 限制：单次最大 10MB / 5 分钟音频

**响应格式**（成功时）：
```json
{
  "output": {
    "choices": [
      {
        "message": {
          "content": [{"text": "识别文本"}]
        }
      }
    ]
  }
}
```

**transcribe_sync.go 完整逻辑**（约 100 行）：

```go
package main

import (
    "bytes"
    "encoding/base64"
    "encoding/json"
    "fmt"
    "io"
    "net/http"
    "os"
    "strings"
    "time"
)

const qwen3ASREndpoint = "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"

// qwen3Hotwords 启动时从 hotwords.txt 加载，供 system message 使用
var qwen3Hotwords string  // 逗号分隔的词表字符串

func initQwen3Hotwords() {
    path := findHotwordsFile()
    if path == "" {
        return
    }
    words, err := loadHotwordsFromFile(path)
    if err != nil {
        return
    }
    var names []string
    for _, w := range words {
        names = append(names, w.Word)
    }
    qwen3Hotwords = strings.Join(names, ", ")
}

func transcribeSyncHandler(apiKey string) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        if r.Method != http.MethodPost {
            writeError(w, http.StatusMethodNotAllowed, "method not allowed")
            return
        }

        if err := r.ParseMultipartForm(maxUploadSize); err != nil {
            writeError(w, http.StatusBadRequest, fmt.Sprintf("parse form: %v", err))
            return
        }

        file, _, err := r.FormFile("file")
        if err != nil {
            writeError(w, http.StatusBadRequest, fmt.Sprintf("get file: %v", err))
            return
        }
        defer file.Close()

        audioData, err := io.ReadAll(file)
        if err != nil {
            writeError(w, http.StatusInternalServerError, fmt.Sprintf("read file: %v", err))
            return
        }

        start := time.Now()
        text, err := transcribeWithQwen3(apiKey, audioData)
        if err != nil {
            writeError(w, http.StatusInternalServerError, fmt.Sprintf("transcribe: %v", err))
            return
        }
        durationMs := time.Since(start).Milliseconds()

        writeJSON(w, http.StatusOK, map[string]any{
            "text":        text,
            "duration_ms": durationMs,
        })
    }
}

func transcribeWithQwen3(apiKey string, audioData []byte) (string, error) {
    b64 := base64.StdEncoding.EncodeToString(audioData)
    audioURI := "data:audio/wav;base64," + b64

    systemText := qwen3Hotwords  // 热词作为 corpus

    type contentItem map[string]string
    type message struct {
        Role    string        `json:"role"`
        Content []contentItem `json:"content"`
    }
    type requestBody struct {
        Model  string `json:"model"`
        Input  struct {
            Messages []message `json:"messages"`
        } `json:"input"`
        Parameters struct {
            ASROptions struct {
                LanguageHints []string `json:"language_hints"`
            } `json:"asr_options"`
        } `json:"parameters"`
    }

    var req requestBody
    model := os.Getenv("ASR_SYNC_MODEL")
    if model == "" {
        model = "qwen3-asr-flash"
    }
    req.Model = model

    var msgs []message
    if systemText != "" {
        msgs = append(msgs, message{
            Role:    "system",
            Content: []contentItem{{"text": systemText}},
        })
    }
    msgs = append(msgs, message{
        Role:    "user",
        Content: []contentItem{{"audio": audioURI}},
    })
    req.Input.Messages = msgs
    req.Parameters.ASROptions.LanguageHints = []string{"zh", "en"}

    body, err := json.Marshal(req)
    if err != nil {
        return "", fmt.Errorf("marshal request: %w", err)
    }

    httpReq, err := http.NewRequest(http.MethodPost, qwen3ASREndpoint, bytes.NewReader(body))
    if err != nil {
        return "", fmt.Errorf("create request: %w", err)
    }
    httpReq.Header.Set("Content-Type", "application/json")
    httpReq.Header.Set("Authorization", "Bearer "+apiKey)

    client := &http.Client{Timeout: 60 * time.Second}
    resp, err := client.Do(httpReq)
    if err != nil {
        return "", fmt.Errorf("http request: %w", err)
    }
    defer resp.Body.Close()

    respBody, err := io.ReadAll(resp.Body)
    if err != nil {
        return "", fmt.Errorf("read response: %w", err)
    }

    if resp.StatusCode != http.StatusOK {
        return "", fmt.Errorf("api error %d: %s", resp.StatusCode, string(respBody))
    }

    // 解析响应
    var result struct {
        Output struct {
            Choices []struct {
                Message struct {
                    Content []struct {
                        Text string `json:"text"`
                    } `json:"content"`
                } `json:"message"`
            } `json:"choices"`
        } `json:"output"`
    }
    if err := json.Unmarshal(respBody, &result); err != nil {
        return "", fmt.Errorf("parse response: %w", err)
    }
    if len(result.Output.Choices) == 0 ||
        len(result.Output.Choices[0].Message.Content) == 0 {
        return "", fmt.Errorf("empty response")
    }
    return result.Output.Choices[0].Message.Content[0].Text, nil
}
```

**修改文件**：`asr-bridge/main.go`

在 `initHotwords(apiKey)` 后增加：
```go
initQwen3Hotwords()
```

在路由注册中增加：
```go
mux.HandleFunc("/v1/transcribe-sync", transcribeSyncHandler(apiKey))
```

在常量区增加（可选，用于文档说明）：
```go
// ASR_SYNC_MODEL 环境变量覆盖（默认 qwen3-asr-flash）
```

#### 1.2 Swift 侧：松手后发起二次识别竞赛

**修改文件**：`speaklow-app/Sources/AppState.swift`

**设计原则**：
- 流式结果（`streamingResult`）作为 fallback，优先级低
- qwen3 结果优先，但受超时约束
- 超时策略：`max(3秒, 录音时长 × 0.3)`，最长不超过 15 秒
- 录音超过 5 分钟直接跳过 qwen3（超出其 API 限制）

**新增实例变量**（streaming state 区域）：
```swift
private var streamingResult: String = ""
private var wavFileURL: URL?       // 本次录音的 WAV 文件路径（优化 0 写入后可用）
private var recordingDuration: TimeInterval = 0
```

**修改 `_beginRecordingAfterHealthCheck()`**：
- 在 `self.committedSentences = []` 附近重置：
  ```swift
  self.streamingResult = ""
  self.wavFileURL = nil
  self.recordingDuration = 0
  ```

**修改 `stopStreamingRecording()`**：
- 在调用 `audioRecorder.stopRecording()` 前记录录音时长：
  ```swift
  if let start = recordingStartTime {
      recordingDuration = Date().timeIntervalSince(start)
  }
  ```
- `audioRecorder.stopRecording()` 改为：
  ```swift
  wavFileURL = audioRecorder.stopRecordingWithFile()  // 新方法，见优化 0
  ```
  注意：如果 AudioRecorder 已有文件写入，直接用 `stopRecording()` 返回值。

**修改 `streamingDidFinish()`**：

原来的逻辑（fullText 为空 → 显示错误，不为空 → LLM refine → 插入）替换为：

```swift
func streamingDidFinish() {
    guard isStreaming else { return }
    streamingHasFinished = true
    viLog("Streaming: finished")

    isStreaming = false
    streamingStallTimer?.invalidate()
    streamingStallTimer = nil
    streamingService?.disconnect()
    streamingService = nil
    audioRecorder.onStreamingAudioChunk = nil

    transcribingIndicatorTask?.cancel()
    transcribingIndicatorTask = nil

    var fullText = committedSentences.joined()
    if fullText.isEmpty && !lastPartialText.isEmpty {
        viLog("Streaming: using partial as final: '\(lastPartialText.prefix(40))'")
        fullText = lastPartialText
    }

    if fullText.isEmpty {
        statusText = "未检测到语音"
        NSSound(named: "Basso")?.play()
        overlayManager.dismissPreviewPanel()
        overlayManager.showError(title: "未检测到语音", suggestion: "请靠近麦克风说话")
        audioRecorder.cleanup()
        return
    }

    // 保存流式结果作为 fallback
    streamingResult = fullText

    // 尝试 qwen3 二次识别
    let duration = recordingDuration
    let wavURL = wavFileURL
    let shouldTryQwen3 = wavURL != nil && duration < 300  // 5 分钟内且有 WAV 文件

    if shouldTryQwen3, let url = wavURL {
        let timeout = max(3.0, duration * 0.3)
        viLog("Streaming: launching qwen3 sync ASR, timeout=\(String(format: "%.1f", timeout))s, duration=\(String(format: "%.1f", duration))s")

        overlayManager.updatePreviewText("✨ 优化识别中...")

        Task {
            let finalText = await transcribeSyncWithFallback(
                wavURL: url,
                fallbackText: fullText,
                timeout: timeout
            )
            await MainActor.run {
                self.applyFinalTranscript(finalText)
            }
        }
    } else {
        if !shouldTryQwen3 {
            viLog("Streaming: skipping qwen3 (duration=\(String(format: "%.0f", duration))s, wavURL=\(wavURL?.path ?? "nil"))")
        }
        // 直接走 LLM refine
        applyFinalTranscript(fullText)
    }

    audioRecorder.cleanup()
}

/// 带超时的 qwen3 二次识别，失败时返回 fallbackText
private func transcribeSyncWithFallback(wavURL: URL, fallbackText: String, timeout: TimeInterval) async -> String {
    let bridgeURL = URL(string: "http://127.0.0.1:18089/v1/transcribe-sync")!

    do {
        let data = try Data(contentsOf: wavURL)
        let result = try await withTimeout(seconds: timeout) {
            try await self.postMultipartAudio(to: bridgeURL, audioData: data)
        }
        if let text = result, !text.isEmpty {
            viLog("qwen3 sync: got '\(text.prefix(40))' (used qwen3 result)")
            return text
        }
    } catch {
        viLog("qwen3 sync: failed or timeout: \(error.localizedDescription), using streaming fallback")
    }
    return fallbackText
}

/// 向 bridge 发 multipart 音频，返回识别文本
private func postMultipartAudio(to url: URL, audioData: Data) async throws -> String? {
    let boundary = UUID().uuidString
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var body = Data()
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
    body.append(audioData)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
    request.httpBody = body

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw NSError(domain: "TranscribeSync", code: -1, userInfo: [NSLocalizedDescriptionKey: "HTTP error"])
    }
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return json?["text"] as? String
}

/// 带超时的 async 包装
private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CancellationError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// 公共的最终文字处理（refine + 插入）
private func applyFinalTranscript(_ text: String) {
    lastTranscript = text
    if llmRefineEnabled {
        overlayManager.updatePreviewText("✨ 正在优化...")
        viLog("applyFinalTranscript: starting LLM refine, mode=\(llmRefineMode.rawValue)")
        let mode = llmRefineMode
        Task {
            let refined = await TextRefineService.refine(text: text, mode: mode)
            await MainActor.run {
                self.insertAndFinish(originalText: text, finalText: refined)
            }
        }
    } else {
        insertAndFinish(originalText: text, finalText: text)
    }
}
```

**注意**：原来的 `streamingDidFinish()` 内直接调 LLM refine 和 `insertAndFinish()` 的代码，统一移入 `applyFinalTranscript()`。

**修改范围摘要**（AppState.swift）：
1. 新增实例变量：`streamingHasFinished`, `streamingResult`, `wavFileURL`, `recordingDuration`, `recordingStartTime`
2. `_beginRecordingAfterHealthCheck()`：重置新增变量，在 `onRecordingReady` 中记录 `recordingStartTime`
3. `stopStreamingRecording()`：记录 `recordingDuration`，保存 WAV 路径，增加 200ms 最短时长守卫
4. `streamingDidFinish()`：完全重写（含 Bug 1、Bug 3 修复，以及 qwen3 竞赛逻辑）
5. 新增私有方法：`transcribeSyncWithFallback`, `postMultipartAudio`, `withTimeout`, `applyFinalTranscript`
6. `streamingDidFail()`：入口增加 `streamingHasFinished` 守卫（Bug 1 修复）

**验收标准**：
- 松手后 qwen3 结果在 3 秒内（6s 录音）到 5 秒内（30s 录音）完成并插入
- WAV 文件不可用时（优化 0 未完成），降级为流式结果

---

### 优化 2：热词容错增强（P1）

**文件**：`asr-bridge/hotword.go`

**当前问题**：
1. 启动时热词注册失败 → 整个生命周期无热词，不重试
2. 每次重启无条件 `ReplaceHotwordsFromTextFile`（即使 hotwords.txt 没变）
3. `vocabularyID` 只存内存，进程退出后丢失

**修复方案**：

#### 2.1 vocabularyID 持久化

新增辅助函数，读写 `~/.config/speaklow/vocabulary_id`：

```go
func vocabularyIDCachePath() string {
    home, _ := os.UserHomeDir()
    return filepath.Join(home, ".config", "speaklow", "vocabulary_id")
}

func loadCachedVocabularyID() string {
    data, err := os.ReadFile(vocabularyIDCachePath())
    if err != nil {
        return ""
    }
    return strings.TrimSpace(string(data))
}

func saveCachedVocabularyID(id string) {
    path := vocabularyIDCachePath()
    _ = os.MkdirAll(filepath.Dir(path), 0755)
    _ = os.WriteFile(path, []byte(id), 0600)
}
```

#### 2.2 hotwords.txt 变更检测（SHA256）

新增辅助函数，读写 `~/.config/speaklow/hotwords_hash`：

```go
func hotwordsHashCachePath() string {
    home, _ := os.UserHomeDir()
    return filepath.Join(home, ".config", "speaklow", "hotwords_hash")
}

func computeFileHash(path string) (string, error) {
    data, err := os.ReadFile(path)
    if err != nil {
        return "", err
    }
    sum := sha256.Sum256(data)
    return fmt.Sprintf("%x", sum), nil
}

func loadCachedHash() string {
    data, err := os.ReadFile(hotwordsHashCachePath())
    if err != nil {
        return ""
    }
    return strings.TrimSpace(string(data))
}

func saveCachedHash(hash string) {
    path := hotwordsHashCachePath()
    _ = os.MkdirAll(filepath.Dir(path), 0755)
    _ = os.WriteFile(path, []byte(hash), 0600)
}
```

需要在 `hotword.go` 的 import 中加入 `"crypto/sha256"` 和 `"strings"`。

#### 2.3 修改 `initHotwords()` 逻辑

```go
func initHotwords(apiKey string) {
    hotwordsPath := findHotwordsFile()
    if hotwordsPath == "" {
        log.Println("[hotword] hotwords.txt not found, skipping vocabulary init")
        return
    }
    log.Printf("[hotword] found hotwords.txt at %s", hotwordsPath)

    // 先尝试用缓存的 vocabularyID
    cachedID := loadCachedVocabularyID()
    currentHash, hashErr := computeFileHash(hotwordsPath)
    cachedHash := loadCachedHash()

    if cachedID != "" && hashErr == nil && currentHash == cachedHash {
        // hotwords.txt 没变，直接复用 vocabularyID
        vocabularyID = cachedID
        log.Printf("[hotword] reusing cached vocabularyID=%s (hotwords unchanged)", vocabularyID)
        return
    }

    // 需要重新初始化（首次或文件变了）
    manager, err := hotword.NewManager(hotword.ManagerOptions{
        APIKey: apiKey,
    })
    if err != nil {
        // 尝试用缓存的 ID 继续运行（DashScope 不可达时的降级）
        if cachedID != "" {
            vocabularyID = cachedID
            log.Printf("[hotword] manager init failed (%v), using cached vocabularyID=%s", err, vocabularyID)
        } else {
            log.Printf("[hotword] create manager failed: %v, no cache available", err)
        }
        return
    }

    ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
    defer cancel()

    tables, err := manager.ListHotwordTables(ctx, hotword.ListTablesRequest{
        Prefix: "speaklow",
    })
    if err != nil {
        log.Printf("[hotword] list tables failed: %v, will try creating new", err)
    }

    if len(tables) > 0 {
        vocabularyID = tables[0].VocabularyID
        log.Printf("[hotword] reusing existing table: %s", vocabularyID)
        if _, err := manager.ReplaceHotwordsFromTextFile(ctx, vocabularyID, hotwordsPath); err != nil {
            log.Printf("[hotword] replace hotwords failed: %v (keeping old words)", err)
        } else {
            log.Printf("[hotword] updated hotwords in table %s", vocabularyID)
            // 更新缓存
            saveCachedVocabularyID(vocabularyID)
            if hashErr == nil {
                saveCachedHash(currentHash)
            }
        }
        return
    }

    // 创建新表
    words, err := loadHotwordsFromFile(hotwordsPath)
    if err != nil {
        log.Printf("[hotword] parse hotwords file failed: %v", err)
        return
    }
    table, err := manager.CreateHotwordTable(ctx, hotword.CreateTableRequest{
        Prefix:      "speaklow",
        TargetModel: "paraformer-realtime-v2",
        Words:       words,
    })
    if err != nil {
        log.Printf("[hotword] create table failed: %v", err)
        return
    }
    vocabularyID = table.VocabularyID
    log.Printf("[hotword] created new table: %s (%d words)", vocabularyID, len(words))
    // 保存缓存
    saveCachedVocabularyID(vocabularyID)
    if hashErr == nil {
        saveCachedHash(currentHash)
    }
}
```

**验收标准**：
- 第二次启动时，hotwords.txt 没变，日志显示 "reusing cached vocabularyID"，不调 DashScope API
- 修改 hotwords.txt 后重启，日志显示重新更新表

---

## Phase 3：体验优化

### 优化 3：LLM 按句流式润色（P1）

**文件**：`speaklow-app/Sources/AppState.swift`

**目标**：减少松手后整体等待时间。流式识别期间每收到 `sentence_end` 立即异步润色，松手时大部分已润色完毕。

**与优化 1 的配合策略**：
- 如果 qwen3 二次识别成功：忽略之前按句 refine，用 qwen3 整体结果做单次 refine
- 如果 qwen3 超时/失败：用按句 refine 结果拼接（快路径）

**新增实例变量**：
```swift
// 按句 refine 结果缓存：key = sentence_end 文本，value = refined 文本
private var sentenceRefineCache: [String: String] = [:]
// 正在 refine 的句子计数（用于等待最后一句完成）
private var pendingRefineCount = 0
```

**修改 `_beginRecordingAfterHealthCheck()`**，重置：
```swift
self.sentenceRefineCache = [:]
self.pendingRefineCount = 0
```

**修改 `streamingDidReceiveSentence()`**：
```swift
func streamingDidReceiveSentence(text: String) {
    viLog("Streaming sentence_end: '\(text.prefix(40))'")
    committedSentences.append(text)
    let display = committedSentences.joined()
    overlayManager.updatePreviewText(display)

    // 仅在 LLM refine 启用时触发按句润色
    guard llmRefineEnabled else { return }
    pendingRefineCount += 1
    let mode = llmRefineMode
    Task {
        let refined = await TextRefineService.refine(text: text, mode: mode)
        await MainActor.run {
            self.sentenceRefineCache[text] = refined
            self.pendingRefineCount -= 1
            viLog("Sentence pre-refine done: '\(text.prefix(20))' → '\(refined.prefix(20))'")
        }
    }
}
```

**修改 `applyFinalTranscript()`**（优化 1 引入的方法），增加按句 refine 快路径：

```swift
private func applyFinalTranscript(_ text: String, usePreRefined: Bool = false) {
    lastTranscript = text
    if llmRefineEnabled {
        // 如果启用了按句 refine 且调用方允许使用（非 qwen3 结果）
        if usePreRefined && !sentenceRefineCache.isEmpty {
            // 用预润色的句子拼接
            let refined = committedSentences.map { sentenceRefineCache[$0] ?? $0 }.joined()
            viLog("applyFinalTranscript: using pre-refined sentences")
            insertAndFinish(originalText: text, finalText: refined)
            return
        }

        overlayManager.updatePreviewText("✨ 正在优化...")
        viLog("applyFinalTranscript: starting LLM refine, mode=\(llmRefineMode.rawValue)")
        let mode = llmRefineMode
        Task {
            let refined = await TextRefineService.refine(text: text, mode: mode)
            await MainActor.run {
                self.insertAndFinish(originalText: text, finalText: refined)
            }
        }
    } else {
        insertAndFinish(originalText: text, finalText: text)
    }
}
```

在 `streamingDidFinish()` 中调用时：
- qwen3 成功 → `applyFinalTranscript(qwen3Text, usePreRefined: false)`
- qwen3 失败/超时 → `applyFinalTranscript(streamingResult, usePreRefined: true)`

**验收标准**：15s 以上的录音，松手后明显感受到 refine 时间缩短。

---

### 优化 5：热词表增加 target_lang 字段（P2）

**文件**：`speaklow-app/Resources/hotwords.txt`

**目标**：给英文热词加 `target_lang: zh`，告诉 paraformer 这些英文词出现在中文语流中，提升识别率。

**格式说明**（audio-asr-suite parser 已支持 5 列）：
```
# 格式：词 权重 src_lang tgt_lang（空格分隔）
Claude Code	5	en	zh
Cursor	5	en	zh
```

**具体操作**：遍历 hotwords.txt 中所有英文词条（全部由英文字母/数字组成的），在第 3 列加 `en`，第 4 列加 `zh`。中文词条（含中文字符的）仅保留前 2 列或加 `zh` `zh`。

**注意**：修改后需更新 `~/.config/speaklow/hotwords_hash`（或删除缓存文件），以便下次启动时 bridge 重新同步到 DashScope。

**验收标准**：日志显示 "[hotword] updated hotwords in table"，之后录音时 Claude Code、Cursor 等英文词识别率提升。

---

## Phase 4：探索性优化

### 优化 4：采样率提升探索（P2）

**文件**：`speaklow-app/Sources/AudioRecorder.swift`，`speaklow-app/Sources/StreamingTranscriptionService.swift`

**前置验证**：在动手改代码前，先用 DashScope 文档或测试确认 paraformer-realtime-v2 是否接受 48kHz WAV 输入。如果不支持，此优化无意义。

**方案**（验证通过后）：
- AudioRecorder 中 streaming 路径的 converter 目标采样率从 16000 改为 48000
- chunk size 对应调整：100ms@48kHz/16bit/mono = 9600 bytes
- qwen3-asr-flash 同样需要验证支持的采样率

**目前状态**：搁置，等待验证数据。

---

## 实施顺序总表

```
Phase 1（先做，互不依赖，可并行提交）
├── Bug 1: streamingDidFail 假错误 guard
├── Bug 2: 最小录音时长守卫 (200ms)
├── Bug 3: partial text 兜底
└── 优化 0: AudioRecorder WAV 文件写入确认/修复

Phase 2（Phase 1 完成后）
├── 优化 1: qwen3-asr-flash 二次识别（依赖优化 0）
│   ├── asr-bridge: 新增 transcribe_sync.go
│   ├── asr-bridge/main.go: 注册路由 + initQwen3Hotwords
│   └── AppState.swift: streamingDidFinish 重写
└── 优化 2: 热词容错（独立，可与优化 1 并行）

Phase 3（Phase 2 完成后，可选）
├── 优化 3: LLM 按句流式润色
└── 优化 5: 热词表 target_lang

Phase 4（探索，需先验证）
└── 优化 4: 采样率提升
```

---

## 验收测试清单

| 验收项 | 测试方法 | 通过标准 |
|--------|----------|----------|
| Bug 1 修复 | 录音 10 次，查看日志 | 不出现 "falling back to batch mode" |
| Bug 2 修复 | 快速连按热键 5 次 | 不触发 "funasr task failed" |
| Bug 3 修复 | 录制 "Hello" 等短词 | 不显示"未检测到语音" |
| 优化 0 修复 | 录音 10s，检查临时文件 | WAV 文件 > 320KB（10s × 32KB/s） |
| 优化 1 二次识别 | 录音 10s，测试 5 次 | 松手后 ≤ 5s 完成插入 |
| 优化 1 fallback | 断开网络后录音 | 自动用流式结果，不报错 |
| 优化 2 热词缓存 | 两次启动，观察日志 | 第二次显示 "reusing cached vocabularyID" |

---

## 注意事项

1. **优化 0 是优化 1 的硬性前置**：如果 WAV 文件为空，qwen3 会返回空文本或错误，fallback 到流式结果，不影响用户体验，但优化 1 等于没生效。

2. **`withTimeout` 的 Swift 并发注意**：`TaskGroup` 在 cancel 时不会 throw，使用 `CancellationError` 配合 `checkCancellation()` 确保超时正确传播。

3. **multipart 请求的 Content-Length**：URLSession 默认会计算，不需要手动设置。但 `audioData` 不应超过 10MB（约 5 分钟 WAV），已由 `duration < 300` 守卫保障。

4. **`applyFinalTranscript` 必须在 MainActor 执行**：该方法调用 `overlayManager`（UI），确保从 `await MainActor.run` 块内调用。

5. **热词容错中的 SHA256 import**：`asr-bridge/hotword.go` 需要 `"crypto/sha256"` 和 `"fmt"` 两个新 import。

6. **测试对比脚本**：`test-audio/compare_asr.sh` 已就绪，可用于优化 1 的效果验证。
