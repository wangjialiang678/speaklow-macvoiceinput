# audio-asr-suite 集成提案：封装改进与消费方迁移

> **提案发起方**: speaklow-macvoiceinput（消费方）
> **提案接收方**: audio-asr-suite（组件模块）
> **日期**: 2026-03-02
> **状态**: DRAFT

---

## 1. 背景

speaklow 是一个 macOS 语音转文字桌面工具。按住热键录音，松开后将识别文字插入当前光标位置。架构上采用 Swift app + Go sidecar（asr-bridge）的模式，Go 进程提供 HTTP/WebSocket API 供 Swift 调用。

speaklow 的 Go asr-bridge（980 行，5 个文件）**手动实现了 DashScope FunASR 的 WebSocket 协议**，而 audio-asr-suite 的 Go 模块已经有完整的、经过测试的实现。这份文档分析了为什么会出现重复建设、实际遇到的问题，以及双方应如何改进。

---

## 2. 现状对比

### 2.1 能力矩阵

| 能力 | audio-asr-suite `pkg/` | speaklow `asr-bridge/` | 差距 |
|------|----------------------|----------------------|------|
| DashScope WebSocket 协议 | `internal/provider/funasr/realtime_provider.go`（状态机 + 重连） | `stream.go` 手写（裸连接） | suite 更健壮 |
| 转写结果组装 | `internal/transcript/assembler.go`（去重 + 排序 + SRT 导出） | `transcribe.go` 手写（字符串拼接） | suite 功能更全 |
| 生命周期状态机 | `pkg/asr/session.go`（idle→connecting→connected→finishing→finished→closed） | 无 | speaklow 缺失 |
| 热词管理 | `pkg/hotword/` 完整 CRUD + 文件解析 + CLI | 无 | speaklow 完全缺失 |
| 错误分类 | `pkg/asr/error.go`（AUTH/NETWORK/PROTOCOL/TIMEOUT/SERVER，含 Retryable 标记） | 直接返回 error string | speaklow 缺失 |
| 事件订阅 | `pkg/realtime/` pub/sub EventListener | 无（回调硬编码） | speaklow 缺失 |
| LLM 文本润色 | 无（不属于 ASR 模块职责） | `refine.go` ✅ | speaklow 特有，正确放在消费方 |
| HTTP/WS Bridge Server | `internal/server/`（含 OSS + Redis + 录音文件） | `main.go`（精简 HTTP server） | 各有侧重 |

### 2.2 代码规模

| 项目 | Go 文件数 | 总行数 | 测试覆盖 |
|------|----------|--------|---------|
| audio-asr-suite Go | 47 | ~5000+ | 有单元测试 + 基线测试 |
| speaklow asr-bridge | 5 | 980 | 无测试 |

---

## 3. 真实问题：重复建设的代价

### 3.1 热词表不可用

**问题描述**: speaklow 需要热词表（纠正专业术语、人名、产品名的 ASR 识别错误），但 asr-bridge 没有实现。

**根因**: asr-bridge 手写 DashScope 请求参数时只设了 `semantic_punctuation_enabled` 和 `language_hints`，没有 `vocabulary_id` 或 `hotwords` 字段。而 suite 已有完整的热词管理模块。

**影响**: 用户说"打开 Xcode"可能被识别为"打开叉 code"，无法纠正。

### 3.2 无错误分类，调试困难

**问题描述**: asr-bridge 的错误直接透传为字符串，Swift 端无法区分是认证失败、网络超时还是服务端错误。

**实际场景**: DashScope API Key 过期时，Swift 侧只能看到一个 500 错误和含 WebSocket 堆栈的 error message，无法弹出"请更新 API Key"的针对性提示。

**suite 的解决方案**: `pkg/asr/error.go` 定义了 `ErrorCode`（AUTH_ERROR / NETWORK_ERROR / TIMEOUT_ERROR 等）+ `Retryable` 标记，消费方可以做针对性处理。

### 3.3 流式识别无状态保护

**问题描述**: asr-bridge 的 WebSocket 连接没有生命周期状态机，边界条件处理不完整。

**实际场景**: 用户极快速地按下又松开热键（<200ms），Swift 端在 DashScope 连接尚未建立时就发送了 stop 指令，导致 bridge 进程 panic 或静默丢弃音频。

**suite 的解决方案**: `pkg/asr/session.go` 实现了完整的状态机（idle → connecting → connected → finishing → finished → closed），每个操作都有前置状态检查，乱序调用会返回明确的错误而非 panic。

### 3.4 suite 改进无法同步

**问题描述**: suite 后续的改进（如参数映射优化、超时策略调整、新 provider 支持）speaklow 完全享受不到。

**影响**: 随着两边代码各自演进，差距会持续扩大，最终变成两个完全独立的实现。

---

## 4. 根因分析：为什么 speaklow 没有复用 suite？

### 4.1 Server bridge 在 `internal/` 中，外部项目无法 import

这是最直接的技术原因。suite 的 HTTP/WS bridge server 位于 `internal/server/`，Go 的包可见性规则禁止外部模块导入 `internal/` 下的包。

speaklow 作为独立 Go module（`speaklow/asr-bridge`），只有两个选择：
1. 直接运行 `cmd/asr-server` 二进制 → 但 API 路径不兼容（suite 用 `/api-ws/v1/inference`，speaklow 需要 `/v1/stream`），且没有 LLM refine 端点
2. 自己写一个 bridge → 就是现在的 asr-bridge

### 4.2 suite server 功能过重

即使 server 能被导入，它绑定了 speaklow 不需要的依赖：
- OSS 上传签名 → 桌面 app 不需要
- Redis 任务持久化 → 单用户本地进程不需要
- 录音文件批量识别 → speaklow 只用实时流式
- 说话人分离 → 语音输入场景不需要

### 4.3 API 协议不兼容

| | suite server | speaklow bridge |
|---|---|---|
| 实时 WS 路径 | `/api-ws/v1/inference` | `/v1/stream` |
| WS 协议 | 透传 DashScope 原始协议 | 自定义简化协议（start/audio/stop → partial/final/finished） |
| 健康检查 | `/healthz` | `/health` |
| 业务端点 | 无 | `/v1/refine`（LLM 润色） |

speaklow 的 Swift 客户端（`StreamingTranscriptionService.swift`、`TranscriptionService.swift`）都是按自定义协议写的，直接换 suite server 意味着 Swift 侧全部重写。

### 4.4 小结

> **不是"不想复用"，而是 suite 当时的封装粒度不支持被嵌入式消费。**

---

## 5. 对 audio-asr-suite 的封装建议

### 5.1 将 server bridge 提升为公共包

**建议**: 将 `internal/server/` 的核心能力提升到 `pkg/server/`。

```
pkg/server/
├── bridge.go          # 核心：实时 WS bridge（零外部依赖）
├── options.go         # Config + 功能开关
├── recorded.go        # 可选：录音文件 API（需要 batch provider）
├── storage.go         # 可选：OSS 集成（接口注入）
└── taskstore.go       # 可选：Redis 任务持久化（接口注入）
```

**关键 API**:

```go
type Config struct {
    APIKey       string
    ListenAddr   string              // 仅 standalone 模式
    ServerToken  string              // 可选鉴权
    // 功能开关
    EnableRealtime  bool             // 默认 true
    EnableRecorded  bool             // 默认 false
    EnableHotword   bool             // 默认 false
    // ... 其他可选配置
}

func New(config Config) *Server
func (s *Server) Handler() http.Handler            // 嵌入模式
func (s *Server) RegisterRoutes(mux *http.ServeMux) // 混合模式
func (s *Server) ListenAndServe() error             // 独立模式
```

**消费方用法（speaklow 的目标状态）**:

```go
package main

import (
    "net/http"
    asrserver "github.com/michael/audio-asr-suite/go/audio-asr-go/pkg/server"
)

func main() {
    bridge := asrserver.New(asrserver.Config{
        APIKey:         os.Getenv("DASHSCOPE_API_KEY"),
        EnableRealtime: true,
    })

    mux := http.NewServeMux()
    bridge.RegisterRoutes(mux)

    // speaklow 自己的业务端点
    mux.HandleFunc("/v1/refine", refineHandler)
    mux.HandleFunc("/health", healthHandler)

    http.ListenAndServe(":18089", mux)
}
```

### 5.2 支持 API 路径自定义

不同消费方对路径有不同需求，不应强制统一：

```go
bridge.RegisterRoutes(mux, asrserver.RouteOptions{
    RealtimeWSPath:  "/v1/stream",         // speaklow 需要
    TranscribePath:  "/v1/transcribe",     // speaklow 需要
    HealthPath:      "/health",            // speaklow 需要
    // 不注册不需要的路由
})
```

### 5.3 按需初始化，不强制拉入重依赖

当前 `internal/server/` 即使不用 OSS/Redis，编译时也会拉入 `aliyun-oss-go-sdk` 和 `go-redis` 依赖。对 speaklow 这种嵌入式场景，这会增大二进制体积和编译时间。

**建议**：
- 核心 bridge（实时 WS + 健康检查）零外部依赖
- OSS、Redis、录音文件识别等通过接口注入，不使用时零开销
- 考虑 Go build tags 或子包拆分

### 5.4 WS 协议适配层

suite 当前透传 DashScope 原始协议给客户端。但对移动端/桌面端消费方来说，DashScope 协议太底层（需要处理 task-started、result-generated、task-finished 等事件类型）。

**建议**: 在 `pkg/server/` 中提供可选的协议简化层：

```go
type WSProtocol string
const (
    WSProtocolRaw      WSProtocol = "raw"        // 透传 DashScope
    WSProtocolSimple   WSProtocol = "simple"     // partial/final/finished 简化协议
)
```

这样 speaklow 不需要在 Swift 端解析 DashScope 协议细节。

### 5.5 暴露 `pkg/realtime` 的参数传递通道

即使不用 server bridge，消费方也应该能方便地把热词 ID 传给实时识别。当前 `realtime.ModuleOptions` 的 `Parameters` 字段是 `asr.FunASRRunTaskParameters` 结构体，需要确认它包含 `VocabularyID` 字段：

```go
type FunASRRunTaskParameters struct {
    SemanticPunctuationEnabled *bool
    MaxSentenceSilence         *int
    LanguageHints              []string
    VocabularyID               string    // <-- 需要确认此字段存在
    Hotwords                   string    // <-- 或支持内联热词
}
```

---

## 6. speaklow 侧的迁移计划

### Phase 1：引入 suite `pkg/` 依赖（suite 无需改动）

即使 suite 暂不改动 `internal/server/`，speaklow 也可以先受益：

1. `asr-bridge/go.mod` 添加 suite 模块依赖
2. `transcribe.go` 用 `pkg/realtime.Module` 替代手写的 DashScope WebSocket 调用
3. `stream.go` 用 `pkg/realtime.Module` + 事件订阅替代手写的三方中继
4. 通过 `pkg/hotword.Manager` 获得热词能力
5. 保留 `main.go`（HTTP 路由壳）和 `refine.go`（LLM 业务逻辑）

**预期效果**:
- `transcribe.go` 从 242 行缩减到 ~60 行
- `stream.go` 从 362 行缩减到 ~100 行
- 自动获得状态机保护、错误分类、转写组装等能力
- 热词支持立即可用

### Phase 2：切换到 `pkg/server/`（suite 改造后）

suite 将 server 提升到 `pkg/server/` 后：

1. speaklow 的 asr-bridge 简化为 `main.go`（~30 行路由配置）+ `refine.go`（~140 行业务逻辑）
2. 删除 `transcribe.go` 和 `stream.go`
3. 总代码量从 980 行降至 ~200 行

---

## 7. speaklow 的具体应用场景

供 suite 团队在设计 API 时参考：

### 7.1 嵌入式 sidecar 模式

speaklow 的 Go bridge 作为 macOS app 的子进程运行：
- Swift app 通过 `Process()` 启动 Go 二进制
- 监听 localhost 端口，Swift 通过 HTTP/WS 调用
- app 退出时自动 kill 子进程
- **需求**: 二进制要小（当前 ~10MB，加入 OSS/Redis SDK 后会膨胀）、启动要快（用户感知）

### 7.2 极短录音场景

用户可能按住热键不到 1 秒就松开：
- 音频数据可能只有几百毫秒
- DashScope 连接可能尚未完成
- **需求**: 状态机要能处理 "连接中就收到 finish" 的边界情况

### 7.3 高频启停

用户在聊天场景中可能每 10 秒录一次：
- 每次录音都新建 WebSocket 连接
- **需求**: 连接建立/关闭要干净，无资源泄漏

### 7.4 混合语言输入

用户经常中英混合说话（如"打开 VS Code 的 terminal"）：
- FunASR 有时会把英文词音译成中文
- **需求**: `language_hints: ["zh", "en"]` 要能传递，热词表要支持中英混合

### 7.5 LLM 后处理管线

ASR 输出后还有 LLM 润色步骤：
- 这是 speaklow 特有的业务逻辑，不应进入 ASR 模块
- **需求**: suite 的 bridge 能和业务端点共存于同一个 HTTP server

### 7.6 多种文字插入策略

识别结果需要通过 macOS Accessibility API 插入到任意 app：
- 原生 app（TextEdit）用 AX API 直接写入
- Electron app（VS Code）用 clipboard + Cmd+V
- **需求**: 流式识别的 partial/final 事件要清晰、时序正确，供 Swift 端决定插入策略

---

## 8. 对其他潜在消费方的适用性

基于 speaklow 的经验，以下场景也会遇到类似问题：

| 场景 | 与 speaklow 的共性 | 额外需求 |
|------|-------------------|---------|
| Flutter/移动端 ASR app | 嵌入式 sidecar、精简依赖 | 跨平台编译（gomobile） |
| Electron 桌面转写工具 | localhost bridge、WS 协议 | 浏览器 WS 兼容 |
| CLI 录音转写工具 | 直接用 `pkg/realtime`，不需要 server | 无 UI，纯库调用 |
| Web 会议转写后端 | 需要完整 server（含 OSS/Redis） | 多用户并发、鉴权 |

**结论**: suite 的 `internal/server/` 提升为 `pkg/server/` 后，嵌入式和服务端场景都能受益。精简 profile 对前三种场景尤为重要。

---

## 9. 行动项

### audio-asr-suite 侧

| # | 行动 | 优先级 | 说明 |
|---|------|--------|------|
| S1 | 确认 `FunASRRunTaskParameters` 包含 `VocabularyID` 字段 | P0 | speaklow Phase 1 的前置条件 |
| S2 | 将 `internal/server/` 核心逻辑提升到 `pkg/server/` | P1 | 支持嵌入式消费 |
| S3 | `pkg/server/` 支持路径自定义（`RouteOptions`） | P1 | 兼容已有客户端 |
| S4 | 拆分重依赖（OSS/Redis 可选，不用不编译） | P2 | 控制消费方二进制体积 |
| S5 | 提供简化 WS 协议选项（partial/final/finished） | P2 | 降低客户端复杂度 |

### speaklow 侧

| # | 行动 | 优先级 | 依赖 |
|---|------|--------|------|
| L1 | asr-bridge 引入 suite `pkg/realtime` + `pkg/hotword` 依赖 | P0 | S1 |
| L2 | 用 `pkg/realtime.Module` 替代手写 DashScope 调用 | P0 | L1 |
| L3 | 接入热词表管理 | P1 | L1 |
| L4 | 切换到 `pkg/server/` 嵌入模式 | P2 | S2, S3 |

---

## 附录 A：speaklow asr-bridge 当前文件清单

```
asr-bridge/
├── main.go         (187 行) HTTP server 路由 + 中间件
├── transcribe.go   (242 行) 一次性转写，手写 DashScope WS 协议
├── stream.go       (362 行) 流式转写，三方 WS 中继
├── refine.go       (142 行) LLM 文本润色（调 DashScope OpenAI 兼容 API）
├── env.go          ( 47 行) .env 文件加载
├── go.mod                   依赖：gorilla/websocket + godotenv
└── go.sum
```

## 附录 B：speaklow Swift-Go API 协议

### POST /v1/transcribe
```
Request:  multipart/form-data { file, model?, sample_rate?, format? }
Response: { "text": "...", "duration_ms": 123 }
```

### WebSocket /v1/stream
```
Client → Bridge:
  { "type": "start", "model": "...", "sample_rate": 16000, "format": "pcm" }
  { "type": "audio", "data": "<base64>" }
  { "type": "stop" }

Bridge → Client:
  { "type": "started" }
  { "type": "partial", "text": "..." }
  { "type": "final", "text": "..." }
  { "type": "finished" }
  { "type": "error", "error": "..." }
```

### POST /v1/refine
```
Request:  { "text": "...", "mode": "correct|polish|both" }
Response: { "refined_text": "...", "duration_ms": 123, "fallback": false }
```
