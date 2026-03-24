# 音频格式要求

## DashScope ASR 的音频输入要求

| 参数 | 要求 |
|------|------|
| 采样率 | 16kHz |
| 声道 | 单声道（mono） |
| 位深 | 16-bit signed integer |
| 字节序 | 小端（little-endian） |
| 格式 | PCM raw（流式）/ WAV（批量） |

这是 qwen3-asr-flash 系列模型的标准输入格式。其他采样率或格式需要预先转换。

## 批量模式的音频准备

批量模式通过 REST API 上传，音频需要：

1. 转换为 16kHz 单声道 WAV
2. Base64 编码
3. 拼接为 data URI: `data:audio/wav;base64,{编码后数据}`

### 格式转换

如果录音设备输出的不是 16kHz WAV，需要先转换。macOS 上可以用 `afconvert`：

```bash
afconvert input.m4a -o output.wav -d LEI16 -f WAVE --quality 127 -r 16000
```

其他平台可用 ffmpeg：

```bash
ffmpeg -i input.mp3 -ar 16000 -ac 1 -f wav output.wav
```

## 流式模式的音频帧

流式模式发送原始 PCM 数据（无 WAV 头），每帧建议：

- **帧大小**: 3,200 字节 = 100ms 音频
- **计算**: 16,000 采样/秒 × 2 字节/采样 × 0.1 秒 = 3,200 字节
- **编码**: Base64 后发送

帧太小会增加网络开销，帧太大会增加延迟。100ms 是实测较好的平衡点。

## 静音检测

建议在发送前做静音检测，过滤纯静音帧：

- **RMS 阈值**: 约 150（在 int16 范围内）
- **计算方法**: 对每帧所有采样值求均方根
- **作用**: 减少网络带宽，更重要的是避免 ASR 在纯静音时产生幻觉输出（比如凭空识别出"嗯"、"啊"）

## 录音文件管理建议

- 保留最近 N 个录音文件用于调试（建议 20 个）
- 文件命名带时间戳：`recording-yyyyMMdd-HHmmss.wav`
- 存放在用户缓存目录，不要用系统临时目录（macOS 的 `/tmp` 会被系统清理，但时机不确定）
