# DashScope ASR API 接口参考

## 1. 批量转写（REST API）

### 基本信息

- **模型**: `qwen3-asr-flash`
- **端点**: `POST https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation`
- **认证**: `Authorization: Bearer {API_KEY}`
- **Content-Type**: `application/json`
- **超时建议**: 30 秒

### 请求体

```json
{
  "model": "qwen3-asr-flash",
  "input": {
    "messages": [
      {
        "role": "system",
        "content": [
          { "type": "text", "text": "热词语料文本（可选）" }
        ]
      },
      {
        "role": "user",
        "content": [
          { "type": "audio", "audio": "data:audio/wav;base64,{BASE64_DATA}" }
        ]
      }
    ]
  },
  "parameters": {
    "asr_options": {
      "language_hints": ["zh", "en"]
    }
  }
}
```

**说明**:
- 音频通过 data URI 格式内嵌在请求中，不需要上传到 OSS
- `language_hints` 指定识别语言，支持中英混合
- system message 用于传递热词语料（见下方热词章节），不需要热词时可省略整个 system message

### 响应体

```json
{
  "output": {
    "choices": [
      {
        "message": {
          "content": [
            { "type": "text", "text": "识别出的文本" }
          ]
        }
      }
    ]
  }
}
```

取文本路径: `response.output.choices[0].message.content[0].text`

### 限制

- 单次请求最大 10MB / 5 分钟音频
- 热词总量上限 10,000 tokens

---

## 2. 流式转写（WebSocket）

### 基本信息

- **模型**: `qwen3-asr-flash-realtime`
- **端点**: `wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime`
- **认证 Header**:
  - `Authorization: Bearer {API_KEY}`
  - `OpenAI-Beta: realtime=v1`
- **协议**: 基于 OpenAI Realtime API 协议

### 连接流程

#### 第一步：建立连接

WebSocket 连接建立后，DashScope 会主动发送 `session.created` 事件。

#### 第二步：配置会话

收到 `session.created` 后，发送 `session.update` 配置音频参数和热词：

```json
{
  "event_id": "evt_001",
  "type": "session.update",
  "session": {
    "modalities": ["text"],
    "input_audio_format": "pcm",
    "sample_rate": 16000,
    "input_audio_transcription": {
      "language": "zh",
      "corpus": {
        "text": "热词语料文本"
      }
    },
    "turn_detection": null
  }
}
```

**注意**: `turn_detection` 设为 `null` 表示由客户端控制录音边界（推荐）。

#### 第三步：发送音频

将 PCM 音频数据 base64 编码后逐帧发送：

```json
{
  "event_id": "audio_001",
  "type": "input_audio_buffer.append",
  "audio": "{BASE64_PCM_DATA}"
}
```

建议每帧 100ms（3,200 字节 = 16000 采样率 × 2 字节 × 0.1 秒）。

#### 第四步：接收识别结果

DashScope 返回两种消息：

**中间结果**（partial）:
```json
{
  "type": "conversation.item.input_audio_transcription.text",
  "stash": "正在说的部分",
  "text": "已确认的部分"
}
```
- `text`: 已确认不会再变的文本
- `stash`: 当前正在识别、可能还会变的文本
- 显示时拼接: `text + stash`

**完成结果**:
```json
{
  "type": "conversation.item.input_audio_transcription.completed",
  "transcript": "最终识别文本"
}
```

#### 第五步：结束会话

```json
// 1. 提交音频缓冲区
{ "type": "input_audio_buffer.commit" }

// 2. 结束会话
{ "type": "session.finish" }
```

等待收到 `session.finished` 响应后关闭连接。

### 超时建议

| 环节 | 建议超时 |
|------|---------|
| WebSocket 握手 | 20 秒 |
| 单条消息读取 | 120 秒 |
| 结束后等待 `session.finished` | 15 秒 |

---

## 3. 热词（Hotword）

热词通过 system message 的 corpus text 传入，而不是通过 vocabulary_id。

### 格式

在 system message 中以自然语言描述热词列表：

```
本次对话涉及 AI 开发技术，以下专有名词可能出现
（括号内为中文音近说法，听到时请输出英文原文）：
Claude Code（克劳德扣的）, Qwen（千问/千万）, WebSocket, API, ...
```

### 热词表文件格式

每行一个热词，tab 分隔：

```
热词名称	权重	源语言	目标语言	音近提示（可选）
Claude Code	5	en	zh	克劳德扣的
Qwen	5	en	zh	千问/千万
WebSocket	5	en	zh
```

- 权重范围 1-5，5 为最高优先级
- 音近提示帮助 ASR 在听到中文发音时输出英文原词
- 批量模式和流式模式使用相同的 corpus text 格式

### 注意事项

- 热词总量不超过 10,000 tokens
- 热词主要提升专有名词（尤其是中英混杂场景）的识别准确率
- 不需要通过 DashScope 控制台预先创建 vocabulary，直接在请求中传入即可
