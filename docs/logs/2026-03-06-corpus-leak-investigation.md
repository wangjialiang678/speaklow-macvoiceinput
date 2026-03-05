---
title: "Corpus 文本泄漏到识别结果调查"
date: 2026-03-06
status: open
tags: [bug, asr-bridge, qwen3-asr-flash-realtime, hotword]
---

# Corpus 文本泄漏到识别结果

## 现象

用户在使用 SpeakLow 语音输入时，预览面板偶尔会显示热词 corpus 系统提示文本，而非实际语音识别结果。面板上快速滚动显示类似以下内容：

```
本次对话涉及 AI 开发技术，以下专有名词可能出现（括号内为中文音近说法，
听到时请输出英文原文）：Cursor, Claude Code (克劳德扣的), Copilot (扣 pai 了),
TRAE, OpenCode, CLI, CLAUDE.md (克劳德点 MD), Skills, Hooks, sub-agent, MCP, ...
```

该文本随后被当作识别结果走完整插入流程（TextInserter），如果插入失败则显示在文本结果面板中（"文字已复制，按 Cmd+V 粘贴"）。

## 已确认的事实

1. **发生时间**：`2026-03-05T17:12:21Z`，SpeakLow.log 中有完整记录
2. **触发条件**：app 重启后的首次录音（日志显示 `17:11:52 AppState init` → `17:12:19 bridge connected` → `17:12:21 corpus 出现`）
3. **用户观察**：每次重新编译二进制导致 macOS 辅助功能权限重置时更容易出现
4. **表现形式**：corpus 文本以 `Streaming partial:` 形式逐字输出，持续约 3 秒，大量重复的 partial 事件
5. **文本来源**：与 `asr-bridge/hotword.go` 中 `buildCorpusText()` 生成的 corpus.text 完全一致
6. **正常录音不受影响**：corpus 泄漏结束后，后续录音可正常识别

## 数据流路径

```
hotwords.txt → buildCorpusText() → qwen3Hotwords 全局变量
  → setupSession() 中作为 session.update.input_audio_transcription.corpus.text 发送给 DashScope
  → DashScope 以某种方式将 corpus 文本通过 conversation.item.input_audio_transcription.text 事件返回
  → relayDashscopeEvents() 读取 stash/text 字段 → 作为 partial 发给 Swift 客户端
  → 显示在预览面板
```

## 尚未确认的根因

由于问题发生时没有 bridge 侧的原始 DashScope 事件 JSON，无法确认：

- DashScope 返回 corpus 时，文本是在 `text` 字段还是 `stash` 字段？
- 是否有特殊的事件类型（非 `conversation.item.input_audio_transcription.text`）携带了 corpus？
- 是否与 session 初始化时序有关（如 session.update 后立即发送音频，DashScope 尚未完成配置）？
- 是否与权限重置 / bridge 重启的竞态条件有关？

## 已部署的调试方案

在 `asr-bridge/stream.go` 的 `relayDashscopeEvents()` 中添加了针对性 debug log：

```go
// 非 partial 事件：每条都打完整 raw JSON（含 completed、finished、error 等）
if eventType != "conversation.item.input_audio_transcription.text" {
    log.Printf("[stream] event=%s raw=%s", eventType, string(raw[:min(len(raw), 300)]))
}

// partial 事件中检测到 corpus 关键词时：打完整 raw
if strings.Contains(display, "本次对话") || strings.Contains(display, "专有名词") {
    log.Printf("[stream] CORPUS LEAK detected! event raw=%s", string(raw))
}
```

### 查看方式

bridge 的 log 输出到 stderr，被 `ASRBridgeManager.swift` 捕获后写入 `os_log`。查看方式：

```bash
# 实时查看
log stream --predicate 'subsystem == "com.speaklow.app"' | grep "CORPUS LEAK"

# 或在 Console.app 中搜索 "CORPUS LEAK"
```

## 复现尝试记录

| 时间 | 操作 | 结果 |
|------|------|------|
| 01:06 | 手动启动 debug bridge，多次录音 | 未复现 |
| 01:20 | 多次录音测试 | 未复现 |
| 01:27 | 重编译 + 重启 app | 未复现（权限也未被重置） |

## 下次复现时的操作步骤

1. 记录出现时间
2. 立即执行：`log stream --predicate 'subsystem == "com.speaklow.app"' | grep -A5 "CORPUS LEAK"` 查看原始事件
3. 同时检查 `~/Library/Logs/SpeakLow.log` 中该时间段的完整 partial 序列
4. 将原始事件 JSON 保存，用于分析 DashScope 返回的具体字段

## 相关文件

- `asr-bridge/stream.go` — `relayDashscopeEvents()` 函数，DashScope 事件解析和 debug log
- `asr-bridge/hotword.go` — `buildCorpusText()` 函数，corpus 文本生成
- `speaklow-app/Resources/hotwords.txt` — 热词列表源文件
- `speaklow-app/Sources/ASRBridgeManager.swift` — bridge stderr 捕获（写入 os_log）
