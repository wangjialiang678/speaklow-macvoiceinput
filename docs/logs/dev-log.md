---
title: "开发日志"
date: 2026-03-06
status: active
audience: both
tags: [dev-log]
---

# Dev Log: qwen3-asr-flash-realtime 迁移

## 2026-03-06

### 00:15 — 工作流初始化
- 创建分支 `feat/qwen3-realtime`
- 配置：闭环验证=开，编码者=Codex (tcd)
- 任务拆分：2 批（Batch 1: Go 后端, Batch 2: Swift 前端）
- P0 判定标准：`go build ./...` + `make all` 编译通过

### 00:20 — Batch 1: Codex 启动 Go 后端迁移
- Job ID: b266625b, Provider: codex (gpt-5.3-codex xhigh)
- Worktree 分支: tcd/batch1-go-backend
- 耗时: ~7 分钟，1 turn，使用 15% budget

### 00:28 — Batch 1: Codex 完成
改动摘要：
- 删除 `transcribe.go`（72 行，依赖 suite）
- 重写 `stream.go`（373 行，qwen3 realtime WebSocket 协议）
- 重写 `hotword.go`（98 行，纯文本解析 + corpus.text 生成）
- 修改 `transcribe_sync.go`（-22 行，删除 initQwen3Hotwords）
- 修改 `refine.go`（+7 -2 行，音近纠错 prompt）
- 修改 `main.go`（+11 -70 行，默认模型 + 路由清理 + /health 增强）
- 修改 `go.mod`（-3 行，删除 suite 依赖）
- 修改 `hotwords.txt`（新增音近提示列 + 4 个新词条）
- Codex 自行运行 `go build` + `go test` 通过

### 00:30 — Batch 1 合并
- `git merge --no-ff tcd/batch1-go-backend`
- P0 验证: `go build ./...` ✅

### 00:32 — Batch 2: Swift 前端改动（直接执行）
- `StreamingTranscriptionService.swift`: 默认模型 → qwen3-asr-flash-realtime
- `AppState.swift`: LLM refine 默认 → false
- `AppState.swift`: qwen3 流式模型时跳过二次识别

### 00:35 — P0 闭环验证
- `go build ./...` ✅
- `go test ./...` ✅ (no test files)
- `make all` ✅ (编译通过，仅预存 NSUserNotification 弃用警告)

### 结果
- 分支: `feat/qwen3-realtime` (4 commits)
- 净改动: 删除 ~425 行 suite 依赖代码，新增 ~380 行独立实现
- asr-bridge 零外部依赖（仅 gorilla/websocket + godotenv）
- 待手动测试: `make run` → 按住热键说话 → 确认文字正确插入
### 2026-03-13 20:35 — 默认切换到 batch + 收敛单实例启动
- 背景：本机同时运行 `/Applications/SpeakLow.app` 与 `speaklow-app/build/SpeakLow.app`，导致热键、权限检查、日志写入都出现双触发；同时流式 bridge 因上游 `Access denied` 持续崩溃。
- 改动：
- `AppState.swift` 将 `asr_mode` 默认值从 `streaming` 改为 `batch`
- `DiagnosticExporter.swift` 同步使用 `batch` 作为未设置时的默认导出值
- `speaklow-app/Makefile` 在 `all` 后执行 ad-hoc codesign，减少开发版 bundle 身份漂移；`make run` 启动前先清理旧的 `SpeakLow` 与 `asr-bridge` 进程，避免双实例
- 文档：更新 `AGENTS.md` 中的默认模式和运行说明

### 2026-03-13 21:05 — 录音启动失败排查补丁
- 现象：权限已授权，但 batch 模式无法进入有效录音，日志显示 `AVAudioEngine.start()` 最终报 `1937010544 ('stop')`，用户侧只看到 `0ms` 丢弃。
- 改动：
- `AudioRecorder.swift` 在用户选择“默认麦克风”时，先解析系统默认输入设备的真实 UID，再显式绑定到 AUHAL，尽量绕开 `CADefaultDeviceAggregate-*` 路径
- `AppState.swift` 为 batch/streaming 两条录音启动失败路径补充 `viLog` 和错误 overlay，避免静默失败
