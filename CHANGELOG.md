---
title: Changelog
date: 2026-03-06
status: active
audience: human
---

# Changelog

## [Unreleased]

### Fixed
- 修复长按热键不说话时热词 corpus 文本泄漏到 UI 的 bug（三层防线：bridge RMS 静默检测 + bridge isCorpusLeak 过滤 + Swift 端 isCorpusLeak 过滤）
- 修复 Makefile 不自动编译 Go bridge 导致 binary 过期的问题（Go source 变化现在会触发重新编译）

### Changed
- 文档重组：按文档规范整理 docs/ 目录结构（specs/、handbook/、design/、research/）

## [0.5.0] - 2026-03-06

### Changed
- 流式 ASR 从 paraformer-realtime-v2 迁移到 qwen3-asr-flash-realtime（OpenAI Realtime API 协议）
- 移除 audio-asr-suite 依赖，asr-bridge 完全独立
- 移除 `/v1/transcribe` 端点（批量转录），保留 `/v1/transcribe-sync`
- stream.go 完全重写，使用 DashScope OpenAI Realtime WebSocket 协议

## [0.4.0] - 2026-03-05

### Added
- 双阶段 ASR：流式实时预览（paraformer）+ 松手后二次精准识别（qwen3-asr-flash）
- 粘贴验证机制：Cmd+V 后 250ms 延迟读回 AX value 验证插入成功
- 文字结果 fallback 面板：插入失败时弹出浮窗显示可选中文字
- 录音文件保留：最近 20 条录音保存在 ~/Library/Caches/SpeakLow/recordings/

### Fixed
- 修复 Cmd+V 粘贴在 AX 权限中间态被静默丢弃的问题

## [0.3.0] - 2026-03-02

### Added
- audio-asr-suite 集成：用 pkg/realtime.Module 替代手写 DashScope WS 协议
- 热词支持：98 个 AI 开发术语，DashScope vocabulary API 自动创建/复用
- vocabularyID 持久化 + SHA256 变更检测

### Changed
- transcribe.go 和 stream.go 大幅简化（减少 ~480 行）

## [0.2.0] - 2026-03-01

### Added
- LLM 文字优化：qwen-turbo-latest 自动纠错/润色（三种模式）
- 流式识别：边说边显示（WebSocket /v1/stream），逐句插入
- 浮窗实时预览面板
- 中英混合语言提示（language_hints）

### Changed
- 从一次性识别升级为流式识别架构
- 文字插入改为 sentence_end 时逐句粘贴

## [0.1.0] - 2026-02-28

### Added
- 基于 FreeFlow (MIT) 的初始版本
- Swift 菜单栏应用 + Go asr-bridge 双进程架构
- 按住快捷键录音，松开后识别插入
- 三层降级文字插入（AX API → Cmd+V → 剪贴板通知）
- AX 写入读回验证（Electron 假成功检测）
- ASR Bridge 自动启动/健康检查/自动重启
- 麦克风静音超时检测 + 音频引擎自动重建
- 文件日志（~/Library/Logs/SpeakLow.log）
- 中文 UI 和错误提示
