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
