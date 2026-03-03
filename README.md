<p align="center">
  <img src="docs/images/cover.png" alt="SpeakLow Cover" width="100%">
</p>

<h1 align="center">SpeakLow</h1>

<p align="center">
  <strong>macOS 语音输入工具 — 按住说话，松开输入</strong><br>
  <sub>macOS 13.0+ &middot; Apple Silicon & Intel</sub>
</p>

<p align="center">
  <a href="#功能">功能</a> &middot;
  <a href="#安装">安装</a> &middot;
  <a href="#使用">使用</a> &middot;
  <a href="#架构">架构</a> &middot;
  <a href="#构建">构建</a>
</p>

---

## 功能

- **按住即录** — 按住 Right Option / Fn / F5 开始录音，松开停止
- **流式识别** — 边说边显示，实时预览面板展示识别文字
- **自动插入** — 识别文字自动插入光标位置（AX API → 剪贴板+粘贴 → 仅复制 三级降级）
- **AI 文字优化** — 大模型自动纠错、润色，保留中英混排（可关闭）
- **录音波形** — 屏幕顶部 notch 区域实时波形动画
- **热词支持** — 自定义热词表提升 AI 模型名、框架名等专业术语识别率
- **自检自愈** — ASR 服务异常自动重启，麦克风无响应自动重建音频引擎

## 安装

### 从源码构建

```bash
git clone --recurse-submodules https://github.com/MarkShawn2020/speaklow-macvoiceinput.git
cd speaklow-macvoiceinput

# 编译 asr-bridge (Go 1.22+)
cd asr-bridge && go build -o asr-bridge . && cd ..

# 编译 SpeakLow.app
cd speaklow-app && make all && cd ..
```

### 配置 API Key

语音识别依赖阿里云 [DashScope](https://dashscope.console.aliyun.com/apiKey) 服务：

```bash
mkdir -p ~/.config/speaklow
echo 'DASHSCOPE_API_KEY=your-key-here' > ~/.config/speaklow/.env
```

## 使用

```bash
open speaklow-app/build/SpeakLow.app
```

首次运行需授权 **麦克风** 和 **辅助功能** 权限。

### 快捷键

| 操作 | 按键 |
|------|------|
| 录音 | 按住 Right Option / Fn / F5 |
| 停止 | 松开按键 |

### AI 文字优化

| 模式 | 说明 |
|------|------|
| 纠错 | 修正同音字、补充标点 |
| 润色 | 去除口语冗余、优化通顺度 |
| 纠错+润色 | 两者兼顾（默认） |

## 架构

```
SpeakLow.app/
  Contents/
    MacOS/
      SpeakLow        ← Swift 主程序（菜单栏 + 录音 + 浮窗）
      asr-bridge       ← Go HTTP 服务（桥接阿里云 DashScope FunASR）
    Resources/
      hotwords.txt     ← ASR 热词表
```

**数据流：** Swift 录音 → POST 到 asr-bridge (localhost:18089) → WebSocket 转发 DashScope → 返回文字 → 可选 LLM 润色 (qwen-turbo-latest) → 插入光标位置

### 项目结构

```
speaklow-app/          Swift 前端
  Sources/             15 个源文件
  Makefile
asr-bridge/            Go ASR 桥接服务
  main.go              HTTP 路由 (/health, /v1/transcribe, /v1/stream, /v1/refine)
  stream.go            流式转录 (SSE)
  transcribe.go        批量转录
  refine.go            LLM 文字优化
  hotword.go           热词管理
vendor/
  audio-asr-suite/     DashScope ASR 模块 (git submodule)
```

## 构建

### 前置条件

- macOS 13.0+
- Xcode Command Line Tools (`xcode-select --install`)
- Go 1.22+
- DashScope API Key

### 编译

```bash
cd asr-bridge && go build -o asr-bridge .
cd ../speaklow-app && make all
```

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=MarkShawn2020/speaklow-macvoiceinput&type=Date)](https://star-history.com/#MarkShawn2020/speaklow-macvoiceinput&Date)

## License

[Apache-2.0](LICENSE)

Based on [FreeFlow](https://github.com/nicklama/freeflow) (MIT).
