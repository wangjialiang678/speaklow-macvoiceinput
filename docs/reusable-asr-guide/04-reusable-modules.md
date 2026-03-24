# 可复用模块

## Go Bridge（整体可复用）

`asr-bridge/` 目录是一个独立的 Go HTTP 服务，与 Swift 客户端没有代码级依赖，可以整体复制到新项目中使用。

### 需要复制的文件

```
asr-bridge/
├── main.go              # HTTP 路由、中间件、启动入口
├── stream.go            # 流式 WebSocket 转写（三方中继）
├── transcribe_sync.go   # 批量同步转写
├── hotword.go           # 热词文件加载、corpus text 生成
├── refine.go            # LLM 文本优化
├── env.go               # .env 文件加载（优先级链）
├── go.mod               # 依赖声明
└── go.sum               # 依赖锁定
```

### 外部依赖（仅两个）

- `github.com/gorilla/websocket` — WebSocket 连接
- `github.com/joho/godotenv` — .env 文件解析

### 额外需要的文件

```
speaklow-app/Resources/hotwords.txt   # 热词表（复制后按需修改内容）
```

### 复制后需要修改的内容

1. **日志路径**: `main.go` 中的日志文件路径 `~/Library/Logs/SpeakLow-bridge.log`，改为你的项目名
2. **热词内容**: `hotwords.txt` 中的热词替换为你的领域术语
3. **默认端口**: 如需修改默认端口（当前 18089），改 `main.go` 中的常量
4. **CORS 配置**: `main.go` 中的允许来源，根据你的前端地址调整

### 启动方式

```bash
# 设置 API Key（三选一）
export DASHSCOPE_API_KEY=sk-xxx
# 或放在 ~/.config/speaklow/.env
# 或放在二进制同目录的 .env

# 编译运行
cd asr-bridge && go build -o asr-bridge . && ./asr-bridge
```

### 服务端点

| 端点 | 方法 | 用途 |
|------|------|------|
| `/health` | GET | 健康检查 |
| `/v1/stream` | WebSocket | 流式转写 |
| `/v1/transcribe-sync` | POST (multipart) | 批量同步转写 |
| `/v1/refine` | POST | LLM 文本优化 |

## Swift 侧（参考但不直接复用）

Swift 代码与 macOS 应用框架（SwiftUI、AVAudioEngine、Accessibility API）耦合较深，不适合直接复制。但以下逻辑值得参考：

| 文件 | 可参考的逻辑 |
|------|-------------|
| `DashScopeClient.swift` | 批量 ASR 的 REST 调用方式、热词 corpus 构建逻辑 |
| `AudioRecorder.swift` | AVAudioEngine 录音参数、PCM 格式转换、静音检测算法 |
| `StreamingTranscriptionService.swift` | WebSocket 客户端状态机、与 bridge 的消息协议 |

## 架构复用建议

如果你的项目也需要同时支持批量和流式两种模式：

- **策略模式**: 定义统一的转写接口（prepare → begin → finish），批量和流式各自实现
- **模式切换**: 通过配置选择策略实例，主流程代码不出现 `if mode == batch` 分支
- **Bridge 生命周期**: 流式模式需要 bridge 运行，批量模式不需要。切换模式时自动启停 bridge 进程

## API Key 管理

Go bridge 的 API Key 加载优先级：

1. 环境变量 `DASHSCOPE_API_KEY`（最高优先级，适合容器/CI）
2. `~/.config/speaklow/.env`（用户级配置）
3. 可执行文件同目录的 `.env`（开发时方便）

建议新项目保持类似的优先级链，方便不同环境部署。
