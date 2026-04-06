---
title: SpeakLow PRD
date: 2026-03-06
status: active
audience: human
tags: [prd]
---

# SpeakLow - macOS 语音输入应用 PRD

## 产品概述

SpeakLow 是一个 macOS 菜单栏应用，提供系统级语音输入功能。按住快捷键即可录音，松开后自动将语音识别结果插入到当前光标位置。

## 用户故事

1. 用户按住快捷键（Right Option / Fn / F5）开始录音，屏幕顶部显示实时波形
2. 说话过程中，浮窗实时显示识别文字预览（流式识别）
3. 用户松开快捷键，最终识别结果经 LLM 自动纠错润色后插入到当前光标位置
4. 如果自动插入失败，弹出浮窗显示识别文字，供用户手动复制粘贴

## 功能需求

### P0（已实现）

1. **菜单栏常驻**：应用以菜单栏图标形式运行，无 Dock 图标
2. **快捷键录音**：按住 Right Option / Fn / F5 键录音，松开停止
3. **录音波形指示器**：屏幕顶部 notch 区域显示实时波形动画
4. **流式语音识别**：通过本地 asr-bridge 调用 DashScope qwen3-asr-flash-realtime，边说边识别
5. **实时预览**：录音过程中浮窗实时显示识别文字
6. **智能文字插入**（三层降级）：
   - AX API 直接写入（原生 app）→ 读回验证
   - 剪贴板 + Cmd+V 粘贴（Electron app）→ 延迟 250ms 读回验证
   - 浮窗显示文字 + 复制到剪贴板（兜底）
7. **AI 文字优化**：识别后由 LLM（qwen-turbo-latest）自动纠错、润色（可关闭）
8. **热词支持**：自定义热词表提升 AI 开发术语（模型名、框架名等）识别率
9. **自检自愈**：
   - ASR Bridge 异常时自动重启（含端口冲突检测、指数退避重试、单实例守护）
   - 麦克风无响应时自动重建音频引擎
   - 录音生命周期完全由用户热键控制（原"流式识别卡顿自动超时完成"已移除，根因分析见 `docs/logs/dev-log.md`）
10. **权限引导**：首次启动引导用户授权麦克风和辅助功能权限
11. **API Key 配置**：按优先级从环境变量 / `~/.config/speaklow/.env` / App 同级 `.env` 读取
12. **录音文件保留**：最近 20 条录音保存在 `~/Library/Caches/SpeakLow/recordings/`

### P1（已实现）

1. **麦克风选择**：可切换输入设备
2. **快捷键配置**：可切换 Right Option / Fn / F5
3. **开机自启动**：支持 Login Items
4. **LLM 模式选择**：纠错 / 润色 / 纠错+润色（默认）

### P2（未实现）

1. 流式文字插入（边说边写入光标位置，方案已验证未落地）
2. 热词用户自定义 UI
3. 自动更新

### 非目标（明确不做）

- 上下文截图（FreeFlow 的 Context Capture 功能）
- Pipeline 调试面板
- 本地 ASR 模型（始终使用云端）

## 技术架构

```
SpeakLow.app/
  Contents/
    MacOS/
      SpeakLow        ← Swift 主程序（菜单栏 + 录音 + 浮窗）
      asr-bridge       ← Go HTTP/WebSocket 服务（转发到 DashScope）
    Resources/
      AppIcon.icns
      hotwords.txt     ← ASR 热词表
    Info.plist
```

### ASR Bridge（Go）

- 独立二进制，由 Swift App 启动和管理
- 监听 localhost:18089
- 端点：`/health`、`/v1/stream`（WebSocket）、`/v1/transcribe-sync`（POST）、`/v1/refine`（POST）
- 流式识别：通过 OpenAI Realtime API 协议连接 DashScope qwen3-asr-flash-realtime
- 同步识别：通过 REST API 调用 qwen3-asr-flash
- LLM 润色：通过 DashScope OpenAI 兼容 API 调用 qwen-turbo-latest

### Voice Input App（Swift）

- 基于 FreeFlow (MIT) 源码修改
- 17 个 Swift 源文件，swiftc 直接编译（无 Xcode 项目）
- 录音 → 流式 WebSocket 发送 → 实时预览 → 松手 → 最终结果 → LLM 润色 → 文字插入

## API Key 配置优先级

1. 环境变量 `DASHSCOPE_API_KEY`
2. `~/.config/speaklow/.env` 文件
3. App 同级目录的 `.env` 文件

## 系统要求

- macOS 13.0+（Ventura 或更高）
- Apple Silicon 或 Intel（通用二进制）
- 麦克风权限
- 辅助功能权限（用于文字插入和全局快捷键）
- 网络连接（语音识别在云端）
