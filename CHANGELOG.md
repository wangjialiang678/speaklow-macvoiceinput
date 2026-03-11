---
title: Changelog
date: 2026-03-06
status: active
audience: human
---

# Changelog

## [Unreleased]

### Added
- 热词表运行时重载：CLI 命令 `speaklow-reload-hotwords` 同时支持 streaming（Go bridge `/v1/reload-hotwords`）和 batch（DistributedNotification → Swift app）两种模式
- 热词文件优先级链：`HOTWORDS_FILE` 环境变量 > `~/.config/speaklow/hotwords.txt` > bundle `Resources/hotwords.txt`
- 防御性重载：文件不可读时保留旧热词表，不中断功能；文件可读但无热词时正确清空
- Go bridge 热词重载单元测试（9 个用例：格式解析、音近提示、注释跳过、空文件、文件删除保留旧值、环境变量覆盖等）
- 启动时辅助功能权限运行时验证：用 `CGEvent.tapCreate()` 替代不可靠的 `AXIsProcessTrusted()`，准确检测权限 stale 状态
- 文字结果面板关闭按钮（权限异常时全局事件监听失效的保底关闭方式）
- Batch 模式三段状态提示：🎙 正在录音 → 🔍 正在识别 → ✨ 正在优化
- Strategy 模式集成：AppState 通过 TranscriptionStrategy 协议调用 ASR，不再用 switch 分支
- ASRBridgeManager 崩溃自动重启上限（连续 3 次后停止），避免无限循环
- DashScopeClient afconvert 10 秒超时保护 + 音频文件存在性校验

### Fixed
- 修复权限 stale 时无提示、无法插入文本的问题（`AXIsProcessTrusted()` 返回 true 但 CGEvent 被丢弃）
- 修复 AXWebArea（VS Code webview）粘贴验证误判：before=0, after=0 不再视为粘贴失败
- 修复快速按松热键后初始化动画（三个点）不消失的问题（initTimer 竞态条件）
- 修复文字结果面板在新录音开始时未清理的残留问题
- 修复流式录音中 stall detector 误杀活跃录音的问题（已移除 stall detector）
- 修复松开热键后 1 秒无反馈的延迟问题（移除所有路径的 transcribing indicator 延迟）
- 修复 copiedToClipboard 路径下 preview panel（"正在优化..."）和 transcribing panel 未清理的面板泄漏
- 修复长按热键不说话时热词 corpus 文本泄漏到 UI 的 bug（三层防线：bridge RMS 静默检测 + bridge isCorpusLeak 过滤 + Swift 端 isCorpusLeak 过滤）
- 修复 Makefile 不自动编译 Go bridge 导致 binary 过期的问题（Go source 变化现在会触发重新编译）
- 修复 ASRBridgeManager terminationHandler 与 stop() 的竞态条件（统一到主线程）
- 修复 healthTimer 回调在 stop() 后仍可能触发 restart 的竞态
- 修复 DashScopeClient convertTo16kMono 异常路径临时文件泄漏（defer 清理）
- 修复 BatchStrategy.finish() 跨线程调用 recorder.stopRecording() 的线程安全问题
- 修复 AppDelegate Bridge 启动与 asrMode didSet 的重复启动问题（幂等检查）

### Changed
- 默认 ASR 模式从 batch 改为 streaming（实时预览）
- 删除 129 行重复的 stopAndTranscribe()，统一为 stopAndTranscribeBatch()
- ASRBridgeManager.start() 找不到二进制文件时抛出错误而非静默返回
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
