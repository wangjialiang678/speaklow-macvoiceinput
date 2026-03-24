# 阿里云 DashScope 语音识别开发指南

基于 SpeakLow 项目的实战经验整理，帮助开发团队快速接入阿里云 DashScope 语音识别服务。

## 文档索引

| 文档 | 说明 |
|------|------|
| [API 接口参考](01-dashscope-asr-api-reference.md) | 批量转写、流式转写、热词的接口规范 |
| [LLM 文本优化](02-llm-refine-api-reference.md) | 用大模型对 ASR 结果做后处理（纠错、格式化） |
| [音频格式要求](03-audio-format-spec.md) | 采样率、编码、格式转换注意事项 |
| [可复用模块](04-reusable-modules.md) | 哪些代码可以直接复制到新项目 |
| [踩坑记录](05-pitfalls-and-solutions.md) | 开发中遇到的问题和解决方案 |

## 技术栈概览

- **ASR 模型**: qwen3-asr-flash（批量）/ qwen3-asr-flash-realtime（流式）
- **LLM 模型**: qwen-flash（文本优化，可选）
- **认证方式**: DashScope API Key，Bearer Token
- **API Key 获取**: [阿里云 DashScope 控制台](https://dashscope.console.aliyun.com/)

## 两种模式对比

| | 批量模式 | 流式模式 |
|---|---------|---------|
| 协议 | HTTPS REST | WebSocket |
| 延迟 | 录完后一次性识别，700-1400ms | 实时返回中间结果 |
| 适合场景 | 短音频、离线处理 | 实时字幕、语音输入 |
| 音频传输 | base64 整段上传 | 逐帧流式发送 |
| 限制 | 单次 10MB / 5分钟 | 无明确限制 |
| 依赖 | 可直接 HTTP 调用 | 需要 WebSocket 中继服务 |

## 快速开始

1. 获取 DashScope API Key
2. 根据场景选择批量或流式模式
3. 按 [音频格式要求](03-audio-format-spec.md) 准备音频数据
4. 参考 [API 接口参考](01-dashscope-asr-api-reference.md) 发起调用
5. （可选）用 [LLM 优化](02-llm-refine-api-reference.md) 提升输出质量
