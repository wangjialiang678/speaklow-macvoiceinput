---
title: "迁移方案：paraformer 到 qwen3-realtime"
date: 2026-03-05
status: active
audience: ai
tags: [design, migration]
---

# 迁移方案：从 paraformer-realtime-v2 迁移到 qwen3-asr-flash-realtime

> 文档日期：2026-03-05
> 状态：DRAFT
> 前置文档：`docs/OPTIMIZATION_PLAN.md`

---

## 背景

当前 SpeakLow 的流式 ASR 使用 paraformer-realtime-v2（通过 asr-bridge `/v1/stream`），松手后用 qwen3-asr-flash 做二次识别（`/v1/transcribe-sync`）。

用户希望将**流式 ASR 也迁移到 qwen3-asr-flash-realtime**，获得以下收益：

| 维度 | paraformer-realtime-v2 | qwen3-asr-flash-realtime |
|------|----------------------|--------------------------|
| 中文准确率 | 基线 | 更高（同系列 flash 已验证） |
| 英文混合识别 | 依赖 vocabulary_id | 原生支持 context biasing |
| 热词机制 | DashScope vocabulary API（结构化） | `corpus.text`（自由文本，支持音近说明） |
| 音近纠错 | 不支持 | 软性支持（system message 描述音近关系） |

---

## 核心变更

### 1. 流式 ASR 引擎替换

**当前架构**：
```
AudioRecorder → WebSocket → asr-bridge /v1/stream → realtime.Module → DashScope paraformer-realtime-v2
```

**目标架构**：
```
AudioRecorder → WebSocket → asr-bridge /v1/stream → qwen3-asr-flash-realtime WebSocket
```

asr-bridge 的 `/v1/stream` 端点内部实现从 `realtime.Module`（paraformer 协议）切换为直连 DashScope qwen3-asr-flash-realtime WebSocket。

#### qwen3-asr-flash-realtime WebSocket 协议

**端点**：`wss://dashscope.aliyuncs.com/api-ws/v1/inference` （需确认）

**Session 配置**（连接建立后发送）：
```json
{
  "type": "session.update",
  "session": {
    "input_audio_transcription": {
      "model": "qwen3-asr-flash-realtime",
      "corpus": {
        "text": "本次对话涉及 AI 开发技术...(热词+音近说明)"
      },
      "language_hints": ["zh", "en"]
    }
  }
}
```

**音频发送**：二进制帧，PCM 16kHz 16bit mono（与当前格式兼容）

**响应事件**：
- `input_audio_transcription.partial` — 中间结果
- `input_audio_transcription.completed` — 句子完成

> **TODO**：需对照 [官方实时文档](https://www.alibabacloud.com/help/en/model-studio/qwen-real-time-speech-recognition) 确认精确的 WebSocket 协议格式。

### 2. 热词机制迁移

**当前（paraformer）**：
- `initHotwords()` 调用 DashScope Vocabulary API 创建/更新词表 → 得到 `vocabulary_id`
- streaming handler 将 `vocabulary_id` 传给 `realtime.Module`
- hotwords.txt 格式：`词\t权重\tsrc_lang\ttarget_lang`

**目标（qwen3-realtime）**：
- `initQwen3Hotwords()` 读取 hotwords.txt → 构建带音近说明的 corpus text
- streaming handler 在 `session.update` 中通过 `corpus.text` 传入
- 不再需要 DashScope Vocabulary API 调用
- hotwords.txt 格式不变（兼容），但权重/语言字段仅供 corpus text 生成参考

#### corpus.text 升级格式

**当前**（纯词名列表）：
```
Cursor, Claude Code, Copilot, TRAE, CLAUDE.md, ...
```

**目标**（带音近说明）：
```
本次对话涉及 AI 开发技术，以下专有名词可能出现
（括号内为中文音近说法，听到时请输出英文原文）：
Qwen3（千问三/千万三）, qwen3-asr（千万三ASR）,
CLAUDE.md（克劳德点MD）, Claude Code, Cursor, MCP,
sub-agent（子代理）, VS Code, paraformer, DashScope, ...
```

**能力特征**：
- 格式极度自由（词表、段落、混合均可），高度容错
- 音近纠正是**软性偏置**（statistical bias），非强制映射
- 上限 10,000 tokens，当前热词量 ~1000 tokens，远低于上限
- 引用 antirez/qwen-asr 实测："prompt biasing is very soft, spelling instructions are followed decently"

#### 音近说明维护

在 hotwords.txt 中新增可选的第 5 列 `phonetic_hints`：
```
# 格式: 热词<TAB>权重<TAB>src_lang<TAB>target_lang<TAB>音近提示(可选)
Qwen3	5	en	zh	千问三/千万三
qwen3-asr	5	en	zh	千万三ASR
CLAUDE.md	5	en	zh	克劳德点MD
Claude Code	5	en	zh
Cursor	5	en	zh
```

`initQwen3Hotwords()` 读取时，有音近提示的词条格式化为 `Qwen3（千问三/千万三）`，无提示的直接用词名。

### 3. LLM Refine Prompt 增强

在 `refine.go` 的 correct/both prompt 中追加音近纠错段落：

```
【音近技术词纠错】如果出现与英文技术词发音相近的中文，请纠正为正确英文拼写。
例：千万三→Qwen3，千问→Qwen，克劳德→Claude。
注意：仅在明显技术上下文中修正，普通中文不要改。
```

这是 corpus.text 的兜底层——当 ASR 阶段未能纠正时，LLM 有机会补救。

---

## 涉及文件

| 文件 | 变更类型 | 说明 |
|------|---------|------|
| `asr-bridge/stream.go` | **重写** | 从 realtime.Module 切换到 qwen3-realtime WebSocket |
| `asr-bridge/transcribe_sync.go` | 修改 | `initQwen3Hotwords()` 升级为带音近说明的格式 |
| `asr-bridge/hotword.go` | 修改 | 可能简化（不再需要 Vocabulary API 调用，但保留做兼容） |
| `asr-bridge/refine.go` | 修改 | prompt 增加音近纠错段落 |
| `asr-bridge/main.go` | 修改 | 路由/初始化调整 |
| `speaklow-app/Resources/hotwords.txt` | 修改 | 补充 `Qwen3` 等缺失词条，可选加音近提示列 |
| `speaklow-app/Sources/StreamingTranscriptionService.swift` | 可能修改 | 如果 WebSocket 消息格式变了 |

---

## 与 OPTIMIZATION_PLAN.md 的关系分析

### 不受影响（保留）

| 项目 | 理由 |
|------|------|
| **Bug 1**：streamingDidFail 假错误 | 通用 streaming 问题，与 ASR 引擎无关 |
| **Bug 2**：热键双击 200ms 守卫 | 通用录音问题 |
| **Bug 3**：partial text 兜底 | 通用 streaming 问题 |
| **优化 3**：LLM 按句流式润色 | 与 ASR 引擎无关，仅依赖 sentence_end 事件 |

### 需要调整

| 项目 | 影响 | 调整方案 |
|------|------|---------|
| **优化 0**：WAV 文件写入 | 如果保留二次识别仍需要；如果 realtime 够好则降为可选 | **降为 P2**，realtime 迁移后评估是否仍需二次识别 |
| **优化 1**：qwen3-asr-flash 二次识别 | 流式已经是 qwen3 系列，二次识别的边际收益大幅降低（同模型族） | **暂缓**，迁移后实测 realtime 准确率，若已足够好则取消 |
| **优化 2**：热词 vocabulary_id 持久化 | vocabulary_id 仅 paraformer 使用；qwen3-realtime 用 corpus.text 不需要 | **简化**：保留缓存逻辑但不再是核心依赖；若完全弃用 paraformer 则可删除 |
| **优化 5**：hotwords.txt target_lang | paraformer 专属字段；qwen3-realtime 不使用 | **合并**：改为增加音近提示列（第 5 列），target_lang 保留但仅供 paraformer 回退 |

### 被替代

| 项目 | 替代方案 |
|------|---------|
| **优化 4**：采样率提升探索 | qwen3-realtime 可能接受不同采样率，需单独验证 |

### 总结：可合并

两个计划**不冲突**，建议合并为统一的实施路线：

```
Phase 1（Bug 修复，不变）
├── Bug 1: streamingDidFail 假错误 guard
├── Bug 2: 最小录音时长守卫 (200ms)
└── Bug 3: partial text 兜底

Phase 2（核心迁移，替代原 Phase 2）
├── 2A: asr-bridge stream.go 重写 → qwen3-asr-flash-realtime
├── 2B: corpus.text 升级（带音近说明）
├── 2C: hotwords.txt 补充词条 + 音近提示
└── 2D: refine.go prompt 增强

Phase 3（体验优化，保留）
├── 优化 3: LLM 按句流式润色
└── 评估是否仍需二次识别（原优化 1）

Phase 4（清理，新增）
├── 评估移除 paraformer / Vocabulary API 依赖
└── 采样率探索（针对 qwen3-realtime）
```

---

## 风险与待确认项

### 必须确认

1. **qwen3-asr-flash-realtime 的 WebSocket 协议细节**
   - 精确的 endpoint URL
   - 认证方式（Header? Query param?）
   - 音频帧格式（raw PCM? WAV header?）
   - 事件消息格式（partial / sentence_end / final）
   - 是否支持 PCM 16kHz 16bit mono 直传

2. **延迟对比**
   - paraformer-realtime-v2 的首字延迟 vs qwen3-realtime
   - qwen3-realtime 是否有冷启动延迟

3. **稳定性**
   - qwen3-asr-flash-realtime 是否已 GA（非 beta）
   - 并发连接限制
   - 错误恢复机制

### 可控风险

| 风险 | 缓解 |
|------|------|
| qwen3-realtime 延迟高于 paraformer | 保留 paraformer 作为可配置回退 |
| corpus.text 音近纠正不稳定 | LLM refine prompt 兜底 |
| WebSocket 协议不兼容 | asr-bridge 内部封装，Swift 侧无需改动 |

---

## 参考资料

- [Real-time speech recognition - Alibaba Cloud](https://www.alibabacloud.com/help/en/model-studio/qwen-real-time-speech-recognition)
- [Qwen-ASR API Reference](https://help.aliyun.com/zh/model-studio/qwen-asr-api-reference)
- [antirez/qwen-asr (prompt biasing 实测)](https://github.com/antirez/qwen-asr)
- [Qwen3-ASR-Demo HuggingFace](https://huggingface.co/spaces/Qwen/Qwen3-ASR-Demo/blob/main/app.py)
- [Qwen3-ASR Technical Report](https://arxiv.org/html/2601.21337v1)
- [Lightweight Prompt Biasing for ASR](https://arxiv.org/abs/2506.06252)
- [Whisper Prompting Guide (类似机制参考)](https://developers.openai.com/cookbook/examples/whisper_prompting_guide)
- 项目调研报告：
  - `.claude/memory-bank/research/qwen3-asr-context-enhancement-20260305.md`
  - `.claude/memory-bank/research/asr-phonetic-correction-20260305.md`
