---
title: SpeakLow 架构文档
date: 2026-03-06
status: active
audience: both
tags: [architecture]
---

# SpeakLow 架构文档

## 系统概览

两进程架构：Swift 菜单栏应用 + Go HTTP/WebSocket 服务（asr-bridge），通过 localhost:18089 通信。

```
用户按住热键 → AudioRecorder 录音
  → StreamingTranscriptionService (WebSocket) → asr-bridge /v1/stream
    → DashScope qwen3-asr-flash-realtime (OpenAI Realtime API 协议)
    ← 实时返回 partial/final 文本 → RecordingOverlay 浮窗预览
  ← 松手 → 最终文本
  → (可选) /v1/refine → qwen-turbo-latest LLM 润色
  → TextInserter 插入到光标位置
```

## 核心组件

### Swift App（`speaklow-app/Sources/`，17 个文件）

| 文件 | 职责 |
|------|------|
| **AppState.swift** | 中央编排器。录音生命周期、流式识别委托、错误处理、自愈（bridge 重启、音频引擎重建） |
| **ASRBridgeManager.swift** | Go bridge 进程生命周期管理（启动、健康检查、重启） |
| **AudioRecorder.swift** | AVAudioEngine 麦克风录音，静音检测，录音文件保存（~/Library/Caches/SpeakLow/recordings/，最近 20 条） |
| **StreamingTranscriptionService.swift** | WebSocket 客户端，连接 bridge `/v1/stream`，发送 PCM 音频块，接收识别结果 |
| **TranscriptionService.swift** | HTTP POST 批量转录客户端（`/v1/transcribe-sync`） |
| **TextInserter.swift** | 三层降级文字插入：AX API 直接写入 → clipboard+Cmd+V 粘贴 → 浮窗通知。AX 写入后读回验证（Electron 假成功检测），粘贴后 250ms 延迟读回验证 |
| **TextRefineService.swift** | 调用 bridge `/v1/refine` 做 LLM 文字润色 |
| **RecordingOverlay.swift** | notch 区域波形浮窗 + 文字结果 fallback 面板（插入失败时显示可选中文字） |
| **HotkeyManager.swift** | 全局热键监听（Right Option / Fn / F5） |
| **MenuBarView.swift** | 菜单栏图标和下拉菜单 |
| **SettingsView.swift** | 设置面板（热键、麦克风、LLM 模式） |
| **SetupView.swift** | 首次启动权限引导 |
| **EnvLoader.swift** | `.env` 文件加载 |
| **KeychainStorage.swift** | Keychain 存储封装 |
| **AppDelegate.swift** | 应用生命周期 |
| **App.swift** | SwiftUI App 入口 |
| **Notification+VoiceToText.swift** | 通知扩展 |

编译方式：`swiftc` 直接编译所有 17 个 `.swift` 文件（无 Xcode 项目/SPM），Makefile 管理构建流程。

### Go Bridge（`asr-bridge/`，7 个文件）

| 文件 | 职责 |
|------|------|
| **main.go** | HTTP 路由、CORS 中间件、日志中间件、服务初始化 |
| **stream.go** | WebSocket 流式转录。客户端 ↔ Bridge ↔ DashScope 三方中继。使用 OpenAI Realtime API 协议（session.create → session.update → input_audio_buffer.append → session.finish） |
| **transcribe_sync.go** | qwen3-asr-flash 同步 REST API 转录（base64 音频直传） |
| **hotword.go** | 热词表加载（从 `Resources/hotwords.txt`），构建 corpus text 供流式/同步识别使用 |
| **refine.go** | LLM 文字润色（qwen-turbo-latest via DashScope OpenAI 兼容 API） |
| **env.go** | `.env` 文件加载，优先级链 |
| **refine_test.go** | refine 模块单元测试 |

依赖：`gorilla/websocket` + `godotenv`（无 audio-asr-suite 依赖）。

## API 端点

### GET /health

```json
{"status": "ok", "model": "qwen3-asr-flash-realtime"}
```

### WebSocket /v1/stream

```
Client → Bridge:
  {"type": "start", "model": "...", "sample_rate": 16000, "format": "pcm"}
  {"type": "audio", "data": "<base64 PCM>"}
  {"type": "stop"}

Bridge → Client:
  {"type": "started"}
  {"type": "partial", "text": "..."}
  {"type": "final", "text": "...", "sentence_end": true}
  {"type": "finished"}
  {"type": "error", "error": "..."}
```

Bridge 内部通过 OpenAI Realtime API 协议连接 DashScope：
- 连接 `wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime`
- 认证：`Authorization: Bearer {API_KEY}` + `OpenAI-Beta: realtime=v1`
- 事件：`session.created` → `session.update` → `input_audio_buffer.append` → `input_audio_buffer.commit` → `session.finish` → `session.finished`

### POST /v1/transcribe-sync

```
Request:  multipart/form-data { file: WAV/PCM audio }
Response: {"text": "识别文本", "duration_ms": 1234}
```

qwen3-asr-flash 同步 REST API，base64 音频直传。

### POST /v1/refine

```
Request:  {"text": "原文", "mode": "correct|polish|both"}
Response: {"refined_text": "润色后文本", "duration_ms": 123, "fallback": false}
```

## 配置

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `DASHSCOPE_API_KEY` | — | 阿里云 DashScope API 密钥（必须） |
| `ASR_BRIDGE_PORT` | `18089` | bridge HTTP 端口 |
| `ASR_MODEL` | `qwen3-asr-flash-realtime` | 流式 ASR 模型 |
| `ASR_SYNC_MODEL` | `qwen3-asr-flash` | 同步 ASR 模型 |

## 构建与分发

```bash
# 编译 asr-bridge
cd asr-bridge && go build -o asr-bridge .

# 编译 SpeakLow.app（自动复制 asr-bridge 到 .app 包）
cd speaklow-app && make all

# 编译 + 启动
cd speaklow-app && make run

# 创建分发包（zip，含 API key）
cd speaklow-app && make dist

# 创建 DMG 安装包
cd speaklow-app && make dmg
```

## 已知限制

- 未签名应用：macOS 首次启动需右键打开，os_log 日志被过滤（改用文件日志）
- Electron 应用 AX API 假成功：VS Code/Slack 等接受 AX 写入返回 0 但不生效，需读回验证后降级到 Cmd+V
- AX 权限抖动：`AXIsProcessTrusted()` 在应用更新后可能返回 true 但 CGEvent 被静默丢弃，粘贴后需 250ms 延迟验证
- 必须联网：所有 ASR 和 LLM 处理在云端
