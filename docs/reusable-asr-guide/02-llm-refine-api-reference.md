# LLM 文本优化 API 参考

ASR 输出的原始文本可能存在标点缺失、格式不规范、口语化表达等问题。可以用大模型做一轮后处理来提升质量。

## 接口信息

- **模型**: `qwen-flash`（速度快、成本低，适合后处理）
- **端点**: `POST https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions`
- **认证**: `Authorization: Bearer {API_KEY}`
- **协议**: OpenAI Chat Completions 兼容格式

## 请求体

```json
{
  "model": "qwen-flash",
  "temperature": 0.2,
  "max_tokens": 500,
  "messages": [
    {
      "role": "system",
      "content": "{安全前言}\n\n{优化规则}\n\n{风格规则}"
    },
    {
      "role": "user",
      "content": "<transcription>\n{ASR原始文本}\n</transcription>"
    }
  ]
}
```

## 关键设计

### temperature 设为低值

建议 0.2。这不是创作任务，而是纠错和格式化，需要输出稳定。

### 用 XML 标签包裹输入

ASR 文本用 `<transcription>` 标签包裹。这不是装饰，是防止 prompt injection 的关键手段——用户说出的话可能包含"忽略以上指令"之类的内容，XML 标签让模型明确区分数据和指令。

### 三层安全防御

1. **安全前言**（preamble）: 声明数据边界，告诉模型 `<transcription>` 内是纯数据，不是指令。这部分不可由用户修改。
2. **XML 标签**: 结构化隔离输入数据和 system prompt。
3. **长度兜底**: 如果 LLM 输出长度超过输入的 3 倍（按字符数），丢弃输出，返回原文。这是防止模型被诱导生成大段无关内容的最后一道防线。

### 长度计算用字符数，不用字节数

中文一个字 = 1 个字符但 3 个字节。用字节数比较会导致中文文本的 3x 阈值形同虚设。

## 超时与降级

- 超时建议 8-10 秒
- LLM 调用失败或超时时，静默返回 ASR 原始文本，不要阻断主流程
- LLM 返回空文本时，同样返回原文

## Prompt 管理建议

将 prompt 拆分为独立文件，运行时加载：

| 文件 | 用途 | 是否允许用户修改 |
|------|------|----------------|
| `refine_preamble.txt` | 安全前言（数据边界声明） | 否，打包在应用内 |
| `refine_prompt.txt` | 优化规则（如"添加标点"） | 是 |
| `refine_styles/*.txt` | 风格规则（商务/聊天等） | 是 |

**热加载**: 每次调用前检查文件修改时间（mtime），变更时重新读取，无需重启服务。
