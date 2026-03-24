# 踩坑记录

开发过程中遇到的问题和解决方案，按严重程度排序。

---

## P0: Corpus 泄露（ASR 把热词表当识别结果返回）

**现象**: 用户没说话或说了很短的内容，ASR 返回的文本却是热词表本身（system message 的 corpus text 被原样回显）。

**触发条件**: 静音或极短音频 + 包含热词 corpus 的 system message。

**解决方案**: 对 ASR 返回的文本做检测，如果包含 corpus 的特征文本（如"本次对话涉及"、"专有名词可能出现"），丢弃该结果。批量和流式模式都需要做这个检测。

**教训**: 这不是偶发 bug，是 DashScope 在静音输入时的稳定行为。只要你用了热词，就必须加这个过滤。

---

## P0: 流式模式下静音产生幻觉输出

**现象**: 没人说话时，ASR 持续返回"嗯"、"啊"、"呃"等语气词。

**原因**: 环境噪音被 ASR 误识别为语气词。

**解决方案**:
- 发送音频帧前做 RMS 静音检测，低于阈值（约 150）的帧不发送
- 对 ASR 返回的文本做前缀过滤：在第一个实质性词语出现之前，过滤掉纯语气词（"嗯"、"啊"、"呃"、"哦"、"唔"）和标点

**注意**: 只过滤"说话之前"的语气词。一旦出现实质内容，后续的"嗯啊"可能是用户真实表达，不应过滤。

---

## P1: WebSocket 连接后必须等 session.created

**现象**: 连接后立即发送 `session.update`，DashScope 不响应或返回错误。

**正确做法**: WebSocket 连接成功后，等待收到 `session.created` 事件，再发送 `session.update`。这是 OpenAI Realtime API 协议的要求。

---

## P1: 流式结束时必须先 commit 再 finish

**现象**: 直接发送 `session.finish`，最后一段音频的识别结果丢失。

**正确顺序**:
1. 发送 `input_audio_buffer.commit`（提交缓冲区中未处理的音频）
2. 发送 `session.finish`
3. 等待收到 `session.finished` 后关闭连接

---

## P1: turn_detection 必须显式设为 null

**说明**: 如果不设置 `turn_detection`，DashScope 会使用默认的 VAD（语音活动检测），自动判断用户是否说完。这在"按住说话、松开结束"的场景下会导致提前截断。

**解决方案**: 在 `session.update` 中显式设置 `"turn_detection": null`，由客户端控制录音边界。

---

## P2: 不要做 stall detection（文本不变 ≠ 卡住）

**现象**: 流式识别中，partial text 持续返回相同内容，看起来像是 WebSocket 卡住了。

**真实原因**: 用户在录音中沉默（思考、停顿），DashScope 持续发送相同的 partial 是正常行为。

**教训**: 我们最初实现了一个"10 秒文本不变就自动结束录音"的 stall detector，结果 8 次触发中 7 次是误判（用户只是在想），只有 1 次是真正的问题。后来直接删除了这个功能。

**建议**: 录音生命周期应完全由用户控制。不要试图通过文本变化来推断录音是否应该结束。

---

## P2: LLM 优化的长度兜底必须用字符数

**现象**: 中文文本的 3x 长度兜底不生效。

**原因**: 一个中文字符 = 3 个 UTF-8 字节。如果用字节数比较，中文输入的 3x 阈值实际上是 9x，几乎永远不会触发。

**解决方案**: 用字符数（rune count / character count）而非字节数做长度比较。

---

## P2: DashScope OpenAI 兼容模式的端点不同

**容易混淆的两个端点**:

| 用途 | 端点 |
|------|------|
| ASR（语音识别） | `dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation` |
| LLM（文本生成） | `dashscope.aliyuncs.com/compatible-mode/v1/chat/completions` |

ASR 用的是 DashScope 原生 API 格式，LLM 用的是 OpenAI 兼容格式。不要搞混。

---

## P3: WebSocket 认证需要额外 Header

流式 ASR 的 WebSocket 连接需要两个 Header：

```
Authorization: Bearer {API_KEY}
OpenAI-Beta: realtime=v1
```

漏掉 `OpenAI-Beta` 会导致连接被拒绝。注意：浏览器环境的 WebSocket 无法设置自定义 Header，必须通过后端服务中继。

---

## P3: 音频格式不对会静默失败

**现象**: ASR 返回空文本，没有报错。

**可能原因**:
- 采样率不是 16kHz（常见：设备默认 44.1kHz 或 48kHz）
- 不是单声道（立体声会导致识别异常）
- 字节序错误（需要 little-endian）
- WAV 文件头格式不正确

**建议**: 在音频发送前打日志记录格式参数（采样率、声道数、位深），出问题时可以快速定位。

---

## 开发调试建议

1. **保留录音文件**: 出问题时可以用同一段音频重现，大幅减少调试时间
2. **Bridge 日志**: Go bridge 的日志包含完整的 WebSocket 消息收发记录，是排查流式问题的第一手资料
3. **curl 测试批量 API**: 批量模式可以直接用 curl 测试，方便验证 API Key 和网络连通性
4. **小音频先跑通**: 先用一段 2-3 秒的清晰录音跑通整个流程，再处理长音频和边界情况
