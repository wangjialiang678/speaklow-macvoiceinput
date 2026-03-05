# SpeakLow

macOS 语音输入工具。按住快捷键说话，松开后文字自动插入到光标位置。

## 功能

- **按住即录**：按住 Right Option / Fn / F5 开始录音，松开停止
- **流式识别**：边说边显示，实时预览面板展示识别文字（qwen3-asr-flash-realtime）
- **自动插入**：识别文字自动插入到当前光标位置（AX API → 剪贴板+粘贴 → 浮窗复制 三级降级）
- **插入失败浮窗**：当自动插入失败时，弹出浮窗显示可选中的识别文字，按 Cmd+V 粘贴后自动关闭
- **AI 文字优化**：识别后由大模型（qwen-turbo-latest）自动纠错、润色（可关闭）
- **录音波形**：屏幕顶部 notch 区域显示实时波形动画
- **热词支持**：自定义热词表提升专业术语（AI 模型名、框架名等）识别率
- **自检自愈**：ASR 服务异常时自动重启，麦克风无响应时自动重建音频引擎
- **用户友好错误提示**：中文提示 + 操作建议（如"语音服务未启动 / 请重启 SpeakLow"）
- **麦克风选择**：支持切换输入设备
- **开机自启动**：支持 Login Items

## 架构

```
SpeakLow.app/
  Contents/
    MacOS/
      SpeakLow        ← Swift 主程序（菜单栏 + 录音 + 浮窗）
      asr-bridge       ← Go 中间服务（转发到阿里云 DashScope）
    Resources/
      AppIcon.icns
      hotwords.txt     ← ASR 热词表（提升专业术语识别率）
    Info.plist
```

Swift app 通过 WebSocket 连接本地 asr-bridge（localhost:18089），asr-bridge 通过 OpenAI Realtime API 协议连接阿里云 DashScope qwen3-asr-flash-realtime 进行流式识别。识别完成后可选经 LLM（qwen-turbo-latest）优化文字。

## 构建

### 前置条件

- macOS 13.0+
- Xcode Command Line Tools（`xcode-select --install`）
- Go 1.22+（用于编译 asr-bridge）
- DashScope API Key（阿里云语音识别服务）

### 编译

```bash
# 1. 编译 asr-bridge
cd asr-bridge
go build -o asr-bridge .

# 2. 编译 SpeakLow.app（会自动复制 asr-bridge 到 .app 包内）
cd ../speaklow-app
make all
```

### 配置 API Key

按优先级查找 `DASHSCOPE_API_KEY`：

1. 环境变量
2. `~/.config/speaklow/.env`
3. App 同级目录的 `.env`

```bash
mkdir -p ~/.config/speaklow
echo 'DASHSCOPE_API_KEY=your-key-here' > ~/.config/speaklow/.env
```

### 运行

```bash
cd speaklow-app && make run
```

首次运行需要授权**麦克风**和**辅助功能**权限（系统设置 → 隐私与安全性）。辅助功能权限用于将识别文字自动插入到光标位置；未授权时仍可录音识别，但需手动粘贴。

### 分发

```bash
cd speaklow-app && make dist   # 创建 zip（含 API key）
cd speaklow-app && make dmg    # 创建 DMG 安装包
```

## 项目结构

```
speaklow-app/          ← Swift 前端（17 个源文件）
  Sources/
  Info.plist
  Makefile
asr-bridge/            ← Go ASR 桥接服务
  main.go              ← HTTP 路由（/health, /v1/transcribe-sync, /v1/stream, /v1/refine）
  stream.go            ← 流式转录（OpenAI Realtime API 协议 → DashScope）
  transcribe_sync.go   ← qwen3-asr-flash 同步 REST API 转录
  hotword.go           ← 热词表加载与 corpus text 构建
  refine.go            ← LLM 文字优化（qwen-turbo-latest via DashScope）
  env.go               ← .env 文件加载
docs/                  ← 文档
  specs/               ← 规格文档（PRD、架构、测试方案）
  handbook/            ← 用户手册（安装指南、教程、热词说明）
  design/              ← 设计文档（优化方案、迁移方案、集成提案）
  research/            ← 调研报告（ASR 模型对比、流式插入方案验证）
  logs/                ← 过程记录（开发日志）
```

## 文档

### 规格文档
- [产品需求 (PRD)](docs/specs/prd.md)
- [系统架构](docs/specs/architecture.md)
- [测试方案](docs/specs/test-plan.md)

### 用户手册
- [安装指南](docs/handbook/install-guide.md)
- [工作原理](docs/handbook/how-it-works.md)
- [开发教程](docs/handbook/tutorial.md)
- [热词表说明](docs/handbook/hotwords-ai-dev.md)

### 调研报告
- [ASR 模型对比](docs/research/2026-03-05-asr-models-comparison.md)
- [流式文本插入方案验证](docs/research/2026-03-01-streaming-text-insertion.md)

## AI 文字优化

语音识别后可选由大模型自动优化文字，在设置中可开关和切换模式：

| 模式 | 说明 |
|------|------|
| 纠错 (correct) | 修正同音字错误、补充标点 |
| 润色 (polish) | 去除口语化冗余词、优化通顺度 |
| 纠错+润色 (both) | 两者兼顾（默认） |

- 模型：qwen-turbo-latest（通义千问，通过 DashScope OpenAI 兼容 API）
- 延迟：通常 ~500ms
- 降级：超时或失败时静默返回原文，不影响正常使用
- 中英混排保护：英文单词原样保留，不会被翻译成中文

## 热词表

启动时自动加载热词表（`hotwords.txt`），构建 corpus text 传给 qwen3-asr-flash-realtime，提升专业术语识别准确率。

- 热词文件位置：`speaklow-app/Resources/hotwords.txt`
- 格式：`热词<TAB>权重(1-5)<TAB>src_lang<TAB>target_lang`，每行一条
- 包含 98 个 AI 开发领域术语（模型名、框架名、工具名等）
- 热词表详细说明：[docs/handbook/hotwords-ai-dev.md](docs/handbook/hotwords-ai-dev.md)
- 无热词文件时 ASR 仍正常工作（仅缺少术语增强）

## 自检与自愈机制

| 场景 | 检测方式 | 自动恢复 |
|------|----------|----------|
| ASR Bridge 未启动/崩溃 | 录音前 HTTP 健康检查 | 自动重启 bridge 进程 |
| 麦克风无响应（stale engine） | 2 秒静音超时检测 | 销毁并重建音频引擎 |
| 转录失败 | 错误类型分析 | Bridge 相关错误时自动重启 |

## 错误提示

| 场景 | 提示 | 建议 |
|------|------|------|
| Bridge 不可达 | 语音服务未启动 | 请重启 SpeakLow |
| 静音超时 | 麦克风无响应 | 请检查麦克风或重启应用 |
| 转录返回空 | 未检测到语音 | 请靠近麦克风说话 |
| 网络超时 | 网络连接超时 | 请检查网络连接 |
| DashScope 错误 | 识别服务异常 | 请稍后重试 |
| 辅助功能未授权 | 无法自动插入 | 弹出浮窗显示文字 + 引导授权 |

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `DASHSCOPE_API_KEY` | — | 阿里云 DashScope API 密钥（必须） |
| `ASR_BRIDGE_PORT` | `18089` | ASR bridge HTTP 端口 |
| `ASR_MODEL` | `qwen3-asr-flash-realtime` | 流式 ASR 模型 |
| `ASR_SYNC_MODEL` | `qwen3-asr-flash` | 同步 ASR 模型 |

## 许可证

基于 [FreeFlow](https://github.com/nicklama/freeflow) (MIT) 修改开发。
