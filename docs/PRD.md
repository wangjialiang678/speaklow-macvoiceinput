# VoiceInput - macOS 语音输入应用 PRD

## 产品概述

VoiceInput 是一个 macOS 菜单栏应用，提供系统级语音输入功能。按住快捷键即可录音，松开后自动将语音识别结果插入到当前光标位置。后端使用阿里云 FunASR（DashScope API）进行语音识别。

## 用户故事

1. 用户按住 Fn 键开始录音，屏幕顶部显示录音波形
2. 用户松开 Fn 键，音频发送到本地 ASR Bridge 进行识别
3. 识别完成后，文字自动插入到当前光标所在位置
4. 如果插入失败，提示用户并将文字复制到剪贴板

## 功能需求

### P0（MVP 必须）

1. **菜单栏常驻**：应用以菜单栏图标形式运行，无 Dock 图标
2. **快捷键录音**：按住 Fn/Right Option/F5 键录音，松开停止
3. **录音指示器**：屏幕顶部（notch 区域）显示录音波形动画
4. **语音识别**：通过本地 ASR Bridge 调用阿里云 FunASR
5. **智能文字插入**：
   - 优先使用 Accessibility API 直接插入文字到当前光标
   - 如果 AX 插入失败，回退到 剪贴板 + Cmd+V 粘贴
   - 如果粘贴也失败，提示用户文字已复制到剪贴板
6. **权限引导**：首次启动引导用户授权麦克风和辅助功能权限
7. **API Key 配置**：从 .env 文件读取 DASHSCOPE_API_KEY

### P1（优先增强）

1. **麦克风选择**：可选择不同输入设备
2. **快捷键配置**：可切换快捷键
3. **开机自启动**：支持 Login Items

### 不做

1. ~~后处理/LLM 润色~~（去除 FreeFlow 的 PostProcessing 功能）
2. ~~上下文截图~~（去除 FreeFlow 的 ScreenCapture 功能）
3. ~~自动更新~~（去除 FreeFlow 的 UpdateManager）
4. ~~Pipeline 调试面板~~（简化 UI）

## 技术架构

```
VoiceInput.app/
  Contents/
    MacOS/
      VoiceInput       (Swift 主程序)
      asr-bridge       (Go ASR 桥接服务)
    Resources/
      AppIcon.icns
    Info.plist
```

### ASR Bridge（Go）

- 独立二进制，由 Swift App 启动和管理
- 监听 localhost:18089
- HTTP 端点：POST /v1/transcribe（multipart 音频文件）
- 内部通过 WebSocket 连接阿里云 DashScope FunASR
- 返回 JSON：`{"text": "识别文字", "duration_ms": 1234}`

### Voice Input App（Swift）

- 基于 FreeFlow 源码修改
- 移除 Groq API 依赖，改为调用本地 ASR Bridge
- 移除 PostProcessing、Context Capture 等不需要的功能
- 增加智能文字插入（AX API 优先 → 剪贴板回退）
- 增加 Go 进程生命周期管理

## API Key 配置优先级

1. 环境变量 `DASHSCOPE_API_KEY`
2. `~/.config/voiceinput/.env` 文件
3. App 同级目录的 `.env` 文件
4. audio-asr-suite 项目的 `.env` 文件（开发期间）

## 系统要求

- macOS 13.0+
- Apple Silicon 或 Intel（通用二进制）
- 麦克风权限
- 辅助功能权限（用于文字插入和全局快捷键）
