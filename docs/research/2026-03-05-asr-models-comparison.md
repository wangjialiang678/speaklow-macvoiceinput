---
title: "阿里云百炼 ASR 模型调研报告"
date: 2026-03-05
status: active
audience: both
tags: [research, asr]
---

# 阿里云百炼 ASR 模型调研报告

> 调研日期：2026-03-05
> 调研目的：对比各 ASR 模型的价格、性能、功能及适用场景，为 SpeakLow 和会议录音等场景提供选型依据

## 一、模型概览

阿里云百炼平台提供两大系列语音识别模型：

- **Qwen3-ASR 系列**：基于 Qwen3-Omni LLM 的端到端语音大模型，精度高，支持 31+ 语言
- **FunASR/Paraformer 系列**：传统 ASR 架构，功能丰富（说话人分离、时间戳），价格更低

## 二、价格对比

### 实时流式模型

| 模型 | 单价 | 每小时费用 | 备注 |
|------|------|-----------|------|
| **paraformer-realtime-v2** | ¥0.00024/秒 | **¥0.86** | 最便宜的实时模型 |
| **qwen3-asr-flash-realtime** | ¥0.00033/秒 | ¥1.19 | 比 paraformer 贵 38% |
| **fun-asr-realtime** | ¥0.00033/秒 | ¥1.19 | 与 qwen3 实时版同价 |

### 录音文件识别模型（批量/离线）

| 模型 | 单价 | 每小时费用 | 备注 |
|------|------|-----------|------|
| **paraformer-v2** | ¥0.00008/秒 | **¥0.29** | 最便宜，支持说话人分离 |
| **fun-asr** | ¥0.00022/秒 | ¥0.79 | 支持说话人分离 + 情感识别 |
| **qwen3-asr-flash**（短音频） | ≈ ¥0.014/分钟 | ≈ ¥0.84 | 最大 5min/10MB |
| **qwen3-asr-flash-filetrans** | ≈ ¥0.014/分钟 | ≈ ¥0.84 | 最大 12h/2GB |

### 成本优化提示

- qwen3-asr-flash 按音频时长计费，可通过加速原始音频降低成本
- 阿里云百炼提供节省计划，承诺月消费可获阶梯折扣（最高 5.3 折）
- 对于 SpeakLow 日常使用（每天约 30 分钟），即使用最贵的 qwen3-asr-flash-realtime，日均成本也仅约 ¥0.59

## 三、识别精度对比

### Qwen3-ASR-Flash（Flash-1208 API）

| 数据集 | Qwen3-ASR-Flash | Whisper-large-v3 | GPT-4o-transcribe |
|--------|----------------|-----------------|-------------------|
| LibriSpeech test-clean (WER) | **1.33** | 2.0 | - |
| LibriSpeech test-other (WER) | **2.40** | 3.9 | - |
| 中文（多个 benchmark）| 最优 | - | 弱于 Qwen3 |

- qwen3-asr-flash-realtime 比离线版 WER 约高 0.3-0.7 个百分点（流式固有损失）
- **中英混合识别**：两个版本语言能力一致，支持 31+ 语言，但官方无专项 code-switching（如 SEAME）评测数据，不能同时指定多个语言
- **paraformer-realtime-v2**：中文表现优秀，英文弱于 Qwen3 系列

### 模型架构

qwen3-asr-flash 和 qwen3-asr-flash-realtime **基于同一底层模型**（AuT Encoder + Qwen3-Omni LLM backbone），通过 dynamic flash attention window（1s~8s）实现流式/离线两种部署形态，并非不同模型。

## 四、功能对比

### 热词（Hotword / Context Biasing）

| 模型 | 支持 | 传参方式 | 上限 |
|------|------|---------|------|
| qwen3-asr-flash | ✅ | messages system 字段 | 10,000 token |
| qwen3-asr-flash-realtime | ✅ | WebSocket `session.update` → `corpus.text` | 10,000 token |
| paraformer-realtime-v2 | ✅ | vocabulary_id（DashScope 热词表 API） | - |
| fun-asr-realtime | ✅ | vocabulary_id | - |
| paraformer-v2（批量）| ✅ | vocabulary_id | - |

### 说话人分离（Speaker Diarization）

| 模型 | 支持 | 备注 |
|------|------|------|
| **paraformer-v2**（批量） | ✅ | `diarization_enabled: true`，2-100 人 |
| **fun-asr**（批量） | ✅ | 同上，额外支持情感识别 |
| qwen3-asr-flash-filetrans | ❌ | 官方明确标注不支持 |
| qwen3-asr-flash-realtime | ❌ | 不支持 |
| paraformer-realtime-v2 | ❌ | 平台级限制：所有实时流式模型均不支持 |

> **关键结论**：说话人分离是平台级限制——所有实时流式模型均不支持，仅批量录音文件接口支持。且仅支持单声道音频（多声道需先混音）。

### 时间戳

| 模型 | 句级时间戳 | 词级时间戳 | 参数 |
|------|-----------|-----------|------|
| paraformer-v2（批量）| ✅ | ✅ | `timestamp_alignment_enabled: true` |
| fun-asr（批量）| ✅ | ✅ | 同上 |
| qwen3-asr-flash-filetrans | ✅ | ✅ | `enable_words: true` |
| paraformer-realtime-v2 | ✅ | ✅ | Word 对象含 begin_time/end_time |
| fun-asr-realtime | ✅ | ✅ | 同上 |
| qwen3-asr-flash-realtime | ❌ | ❌ | 不支持 |
| qwen3-asr-flash（短音频）| ❌ | ❌ | 不支持 |

### 其他功能

| 功能 | qwen3-flash | qwen3-realtime | paraformer-rt-v2 | paraformer-v2 | fun-asr |
|------|------------|----------------|-----------------|--------------|---------|
| ITN（数字规范化）| ✅ | ❌ | ✅ | ✅ | ✅ |
| 情绪识别 | ❌ | ✅（默认开启）| ❌ | ❌ | ✅ |
| 情感识别 | ❌ | ❌ | ❌ | ❌ | ✅（批量）|
| 音频格式 | 13+ 格式 | 仅 PCM/Opus | 多格式 | 多格式 | 多格式 |
| 采样率 | 多种 | 仅 8k/16k | 8k/16k | 多种 | 多种 |
| 最大时长 | 5min/10MB | 无限（流式）| 无限（流式）| 12h/2GB | 12h/2GB |

## 五、场景推荐

### 场景 1：语音输入工具（SpeakLow）

**当前方案**：paraformer-realtime-v2（流式）+ qwen3-asr-flash（二次识别）

**优化建议**：

| 方案 | 优点 | 缺点 |
|------|------|------|
| **仅用 qwen3-asr-flash-realtime** | 单步完成，延迟最低，精度高 | 贵 38%，不支持 ITN |
| **仅用 paraformer-realtime-v2** | 最便宜，支持时间戳 | 精度略低于 Qwen3 系列 |
| **当前双步方案** | 精度最高（两次识别取优）| 多 700-1400ms 延迟 |

如果追求低延迟，单用 qwen3-asr-flash-realtime 即可（热词支持、精度最高、功能等价）。当前双步方案的主要收益是微提升精度（<1 WER 点），代价是额外延迟。

### 场景 2：会议录音转写

**首选**：`paraformer-v2`（批量接口）
- 配置：`diarization_enabled: true` + `timestamp_alignment_enabled: true`
- 唯一完整支持：说话人区分 + 词级时间戳 + 12 小时长音频
- 价格最低：¥0.29/h

**需要情感分析**：`fun-asr`（批量），价格 ¥0.79/h

**需要最高精度（无需说话人区分）**：`qwen3-asr-flash-filetrans`，¥0.84/h

### 场景 3：实时会议字幕

**首选**：`paraformer-realtime-v2`
- 支持词级时间戳 + 热词 + 多语种
- 价格 ¥0.86/h
- 注意：不支持说话人分离（平台级限制）

## 六、语音降噪方案

SpeakLow 当前**未采用任何降噪处理**。以下是适合 macOS 实时语音输入的降噪方案：

### 方案对比

| 方案 | 延迟 | 模型大小 | CPU 占用 | 集成难度 | 降噪效果 | 中文兼容 |
|------|------|---------|---------|---------|---------|---------|
| **Apple Voice Processing IO** | ~5ms | 0（系统内置）| 极低（Neural Engine）| 极低（3 行代码）| 好 | ✅ |
| **RNNoise** | ~10ms | <100KB | <3% | 低（纯 C 库）| 中等 | ✅ |
| **GTCRN**（via sherpa-onnx）| ~7ms | 48.2K 参数 | 低 | 中等 | 好（ICASSP 2024 SOTA）| ✅ |
| **DeepFilterNet3** | ~20ms | 7MB | 中 | 高（需 Rust 工具链）| 最好 | ✅ |

> 所有神经网络降噪方案均语言无关，不会损伤中文声调特征。

### 推荐实施路径

1. **优先尝试 Apple Voice Processing IO**
   - `inputNode.setVoiceProcessingEnabled(true)`，3 行代码
   - 零依赖、最低延迟、Neural Engine 加速
   - macOS 14+ 有 Voice Isolation（精确人声隔离）
   - ⚠️ 风险：SpeakLow 仅用 inputNode（无 outputNode），需实测兼容性

2. **如有兼容性问题 → RNNoise**
   - 纯 C 库，Swift C interop 直接调用
   - 2024 年 0.2 版加入 AVX2 优化
   - 额外输出 VAD 概率，可替代现有 RMS 静音检测

3. **未来升级 → GTCRN via sherpa-onnx**
   - ICASSP 2024 超轻量 SOTA（48.2K 参数）
   - sherpa-onnx 1.12.x 已有 Swift API 示例和 macOS universal binary
   - RTF 0.07，比 RNNoise 效果更好

### 集成位置

`speaklow-app/Sources/AudioRecorder.swift` 的 AVAudioEngine 初始化段（`engine.prepare()` 之前），或在 tap 回调内下采样之前。

## 七、参考资料

### 官方文档
- [阿里云百炼模型价格](https://help.aliyun.com/zh/model-studio/model-pricing)
- [千问实时语音识别](https://help.aliyun.com/zh/model-studio/qwen-real-time-speech-recognition)
- [千问录音文件识别](https://help.aliyun.com/zh/model-studio/qwen-speech-recognition)
- [Qwen-ASR API 参考](https://help.aliyun.com/zh/model-studio/qwen-asr-api-reference)
- [FunASR/Paraformer 实时识别](https://help.aliyun.com/zh/model-studio/real-time-speech-recognition)
- [FunASR/Paraformer 录音文件识别](https://help.aliyun.com/zh/model-studio/recording-file-recognition)
- [Paraformer 录音识别 RESTful API](https://help.aliyun.com/zh/model-studio/paraformer-recorded-speech-recognition-restful-api)

### 技术报告与开源
- [Qwen3-ASR Technical Report (arXiv)](https://arxiv.org/html/2601.21337v1)
- [Qwen3-ASR GitHub](https://github.com/QwenLM/Qwen3-ASR)
- [Qwen3-ASR-Toolkit](https://github.com/QwenLM/Qwen3-ASR-Toolkit)
- [Qwen3-ASR-1.7B (HuggingFace)](https://huggingface.co/Qwen/Qwen3-ASR-1.7B)

### 降噪方案
- [RNNoise](https://github.com/xiph/rnnoise) - Mozilla 开源实时降噪
- [DeepFilterNet](https://github.com/Rikorose/DeepFilterNet) - SOTA 语音增强
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) - 含 GTCRN 模型的跨平台推理框架
- [Qwen3-ASR-Flash 深度解析 (CSDN)](https://blog.csdn.net/bugyinyin/article/details/151395610)
