# 流式文本插入方案 — 实测验证报告

**日期**: 2026-03-01
**状态**: 已验证，可进入实现阶段

---

## 背景

SpeakLow 当前是"录完再出字"模式。目标：升级为"边说边出字"（流式识别）。
核心挑战不在 ASR API（DashScope FunASR 已支持全双工流式），而在**目标应用中能否实时更新文字**。

## 验证原型

`speaklow-app/prototypes/ax-replace-test.swift` — 单文件命令行工具，测试 4 种文字插入方法。

## 测试方法

| 方法 | 原理 | 适用场景 |
|------|------|---------|
| A: AX 全量替换 | 选中已写入文字 → 用新文字替换 | 原生 app（有闪烁） |
| B: 退格键+重写 | CGEvent Delete × N + AX 重新写入 | 降级方案（不稳定） |
| C: 增量追加 | 只追加 diff（公共前缀跳过） | **原生 app 推荐**（无闪烁） |
| D: 逐句粘贴 | 每句 sentence_end=true 时 clipboard+Cmd+V | **Electron app 兼容** |

## 实测结果

### TextEdit（原生 Cocoa — com.apple.TextEdit）

| 方法 | 结果 | 备注 |
|------|------|------|
| A: 全量替换 | ✅ OK | 每步 AX 读写均正确，但有闪烁 |
| B: 退格+重写 | ✅ OK | 可用但体验差 |
| C: 增量追加 | ✅ OK | **无闪烁，体验最佳** |
| C: 含 ASR 修正 | ✅ OK | 回退+追加正确处理 |

### VS Code（Electron — com.microsoft.VSCode）

| 方法 | 结果 | 备注 |
|------|------|------|
| A: 全量替换 | ❌ 失败 | AX API 返回 success(0) 但不实际写入 |
| B: 退格+重写 | ❌ 失败 | 同上，AX 写入无效 |
| C: 增量追加 | ❌ 失败 | 同上 |
| D: 逐句粘贴 | ✅ OK | clipboard+Cmd+V 正常工作 |

### 关键发现

1. **Electron 应用的 AX 是"假的"**：`setSelectedText` 返回 `code=0` 但不实际修改文本内容。验证（读回 `kAXValueAttribute`）始终返回空字符串。
2. **增量追加（方法 C）在原生 app 体验最佳**：无闪烁、无抖动，仅追加差异部分。
3. **ASR 修正可通过 select+replace 处理**：当 ASR 回退修改已输出的字时，选中需修改的范围，替换为新内容。
4. **逐句粘贴（方法 D）是唯一跨平台通用方案**：虽然不如增量追加流畅，但在所有应用中都能工作。
5. **业界无先例**：调研了 Superwhisper、VoiceInk、MacWhisper 等主流 Mac 语音输入工具，均为录完后一次性插入，无流式替换。

## 确定方案

### 双轨策略

```
收到 ASR 中间结果 (sentence_end=false):
  → 探测目标 app 是否支持 AX 写入
    → 支持: 方法 C（增量追加），实时显示 partial text
    → 不支持: 在 RecordingOverlay 浮窗内显示 partial text

收到 ASR 最终结果 (sentence_end=true):
  → 方法 C 路径: 追加最后一段 diff，完成当前句
  → 方法 D 路径: clipboard+Cmd+V 粘贴整句
```

### 实现里程碑

**Milestone 1（逐句插入）**:
- 接入流式 ASR（Go bridge WebSocket 升级）
- 每个 `sentence_end=true` 立即用方法 D 粘贴（比"录完再出字"快很多）
- RecordingOverlay 显示当前 partial text
- 所有应用兼容

**Milestone 2（原生 app 增量显示）**:
- 探测目标 app 的 AX 写入能力（试写+读回验证）
- 对支持的 app 启用方法 C 增量追加
- 不支持的 app 保持 Milestone 1 行为

**Milestone 3（ASR 修正优化）**:
- 处理 ASR 回退修正（partial text 变短的情况）
- 句间平滑过渡
- 性能调优

## 架构变更

### Go bridge 改动
- 新增 `/v1/stream` WebSocket 端点
- 三方数据流：Swift → Go → DashScope，DashScope → Go → Swift
- 推送格式：`{"type":"partial|final","text":"...","sentence_end":bool}`
- 音频节流：每 100ms 发送 3200 bytes PCM

### Swift 改动
- 新增 `StreamingTranscriptionService`：WebSocket 客户端到 Go bridge
- `AudioRecorder` 新增流式 PCM 输出（tap callback 直接发送，不写文件）
- `TextInserter` 新增 `insertStreaming(partial:)` 接口
- 新增 AX 能力探测（试写+读回验证）
- 保留现有 HTTP POST 路径作为 fallback

## 依赖确认

| 依赖 | 状态 |
|------|------|
| DashScope FunASR paraformer-realtime-v2 全双工 | ✅ 已确认支持 |
| Go gorilla/websocket | ✅ 已有依赖 |
| Swift URLSessionWebSocketTask | ✅ macOS 10.15+ |
| AX API kAXSelectedTextRangeAttribute 写入 | ✅ 原生 app 可用 |
| clipboard+Cmd+V 粘贴 | ✅ 全平台可用 |
