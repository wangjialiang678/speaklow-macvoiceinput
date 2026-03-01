# 从零手搓一个 macOS 语音输入法：我和 AI 结对编程的全过程

> 一个技术小白，用 Claude Code 从零开始，做出了一个按住快捷键就能语音输入的 Mac 应用。全程没写一行代码，全靠和 AI 对话完成。

## 背景

我平时在 Mac 上用 Typeless 做语音输入，按住快捷键说话，松开后文字就出现在光标位置。体验很好，但我想用自己的语音识别后端（阿里云 FunASR），于是决定自己做一个。

我不是专业开发者，但我有一个现成的后端：之前用 Go 写的阿里云 DashScope FunASR 调用模块。我需要的是一个 macOS 前端壳子。

## 第一步：调研——先找轮子，不重复造

### 给 AI 的提示

> "我想自己也用 AI 手搓一个这样的 Mac 应用。请帮我搜索 10 个以上符合我要求的前端开源框架，要求：macOS 原生或跨平台、支持全局快捷键、能录音、开源。"

### AI 做了什么

AI 启动了一个调研子代理，用 `gh search repos` 搜索 GitHub，找到了 **13 个**开源项目并逐一分析：

| 项目 | 语言 | Stars | 许可证 | 评价 |
|------|------|-------|--------|------|
| FreeFlow | Swift | 40+ | MIT | 最简单，纯 Swift，Makefile 构建 |
| VoiceInk | Swift | 1000+ | GPL | 功能最全，但 GPL 限制多 |
| Handy | Tauri/React | 2000+ | MIT | 星最多，但多了一层 Web 技术栈 |
| ... | ... | ... | ... | ... |

### AI 的推荐

最终推荐了 **FreeFlow**，理由：
- MIT 许可，可以自由修改
- 纯 Swift + SwiftUI，没有 Xcode 项目文件，用 Makefile 编译
- 代码量小（19 个文件），容易理解和修改
- 已经实现了全局快捷键、录音、浮窗等核心功能

### 我学到的

**先调研再动手，能省 80% 的时间。** 不需要从零写录音、快捷键、浮窗这些功能，站在别人的肩膀上改就行。

---

## 第二步：确定架构——两个关键决策

AI 问了我两个问题：

### 决策 1：Go 后端怎么和 Swift 前端配合？

- **方案 A**：两个独立进程，用户自己启动 Go 服务
- **方案 B**：把 Go 编译成二进制，塞进 .app 包里，随应用自动启动

**我选了 B。** 一个 .app 搞定一切，用户不需要知道里面有两个程序。

### 决策 2：API 密钥怎么配置？

**我说直接读 `.env` 文件，不要用户手动输入。** 因为我已经有 `.env` 文件了，何必多此一举做个输入框。

### 我的补充需求

> "我希望识别完之后，自动把内容插入到当前光标所在位置。如果插入失败，要提示用户，然后把内容复制到剪贴板。"

---

## 第三步：并行开发——AI 同时写两个组件

AI 先写了 PRD（产品需求文档）和技术设计文档，然后**同时启动两个子代理**：

- **子代理 1**：写 Go ASR Bridge（本地中间服务）
- **子代理 2**：改造 FreeFlow 成 SpeakLow（Swift 前端）

两个子代理独立工作，互不等待。大约几分钟后两边都完成了，编译成功，生成了一个可运行的 `SpeakLow.app`。

### 架构总览

```
SpeakLow.app
├── Contents/MacOS/
│   ├── SpeakLow      ← Swift 主程序（菜单栏 + 录音 + 浮窗）
│   └── asr-bridge       ← Go 中间服务（转发到阿里云）
├── Contents/Info.plist
└── Contents/Resources/AppIcon.icns
```

---

## 第四步：踩坑实录——连续三个串联 bug

应用编译成功，安装也顺利，快捷键能触发录音浮窗。**但说完话松开快捷键后，什么都没发生。** 没有文字，没有报错。

接下来就是漫长的调试过程。

### 坑 1：看不到日志

**现象**：用 `log show` 和 `log stream` 查 macOS 系统日志，完全空白。

**原因**：macOS 的统一日志系统（os_log）对**未签名的应用**会过滤掉日志。我们的应用是用 `swiftc` 直接编译的，没有代码签名。

**解决**：放弃 os_log，自己写了一个文件日志函数 `viLog()`，把日志写到 `~/Library/Logs/SpeakLow.log`。

**教训**：不要假设工具能正常工作，先验证日志确实能看到。

### 坑 2：Accessibility 权限缓存

**现象**：明明在系统设置里给了辅助功能权限，按快捷键还是提示要权限。

**日志证据**：
```
AppState init complete. accessibility=false
handleHotkeyDown() fired
startRecording() entered
AXIsProcessTrusted() = false    ← 明明授权了，为什么还是 false？
```

**原因**：`hasAccessibility` 这个变量只在应用启动时读取一次 `AXIsProcessTrusted()` 的结果。之后用户授权了，但变量没更新。而且每次重新编译二进制，macOS 会撤销之前的信任（因为二进制的 hash 变了）。

**解决**：在每次开始录音前，**实时调用** `AXIsProcessTrusted()` 检查，不依赖缓存值。

**教训**：
1. 权限状态不要缓存，每次用时实时查。
2. 重新编译后记得重新授权（删除再添加，不是关了再开）。

### 坑 3：音频格式不匹配

**现象**：asr-bridge 收到音频了，也发到阿里云了，HTTP 200 成功返回，但识别结果是**空字符串**。

**日志证据**：
```
Audio file size=1674496 bytes
Transcription: HTTP 200, body=30 bytes
Transcription result: '' (length=0)    ← 空的！
```

**排查过程**：

用 curl 直接测试 asr-bridge —— 完全正常，能识别出中文。说明问题不在 asr-bridge，而在发送的音频本身。

**原因**：麦克风录制的 WAV 是 **48kHz、32-bit float**（麦克风原生格式），但阿里云 FunASR 需要 **16kHz、16-bit、单声道** 的音频。asr-bridge 告诉阿里云"这是 16kHz 的音频"，实际上是 48kHz 的，阿里云完全听不懂。

**解决**：在发送前用 macOS 自带的 `afconvert` 命令转换格式：

```
afconvert -f WAVE -d LEI16@16000 -c 1 原始.wav 转换后.wav
```

**教训**：当 API 返回成功但结果为空时，检查输入数据的格式是否符合要求。

### 坑 4：AX API 的"假成功"

**现象**：语音识别成功了（听到了清脆的提示音），但文字没有出现在输入框里。

**日志证据**：
```
TextInserter: frontmost app=Code bundle=com.microsoft.VSCode
TextInserter AX: focused element role=AXTextArea
TextInserter AX: set selected text result=0     ← 0 就是成功
TextInserter: AX insert succeeded                ← 它说成功了！
```

**原因**：我在 VSCode 里测试。VSCode 是 Electron 应用（基于 Chrome 的桌面应用框架），它接受 macOS Accessibility API 的调用并返回"成功"，但**实际上没有执行插入操作**。这是 Electron 应用的已知问题。

**解决**：AX 插入后**验证**——读取文本框内容的长度，如果没变化说明 AX 说谎了，自动降级到剪贴板 + Cmd+V 粘贴：

```
AX: verify before=39 after=39 (expected +32)
AX: value unchanged after set! Falling back.
TextInserter: text set to clipboard, sending Cmd+V
TextInserter: Cmd+V sent, result=true
TextInserter result: pastedViaClipboard    ← 改用粘贴，成功了
```

**教训**：不要信任第三方 API 的返回值，写入后一定要验证。

---

## 第五步：改善体验

功能通了之后，又做了几个改善：

1. **不同提示音**：成功插入播放 "Glass"，失败播放 "Basso"
2. **状态文字**：菜单栏显示识别结果预览，如"已粘贴: 你好这是测试..."
3. **失败通知**：识别失败时弹系统通知，告诉用户具体原因
4. **默认快捷键**：从 Fn 改成 Right Option（因为我的 Fn 键被占了）

---

## 最终成果

一个完整可用的 macOS 语音输入应用：

- 按住 Right Option → 开始录音（屏幕顶部出现波形浮窗）
- 松开 → 自动识别 → 文字插入到光标位置
- 全程约 1-2 秒延迟（取决于网络）
- 支持任何应用的任何输入框

### 技术栈

| 组件 | 技术 | 作用 |
|------|------|------|
| 前端壳 | Swift + SwiftUI | macOS 菜单栏应用、录音、快捷键 |
| 中间桥接 | Go | 本地 HTTP 服务，转发到阿里云 WebSocket |
| 语音识别 | 阿里云 FunASR | 云端 ASR，paraformer-realtime-v2 模型 |
| 文字插入 | macOS AX API + CGEvent | 先尝试 AX 直接插入，失败则 Cmd+V |

### 文件结构

```
mac-typless-cc/
├── asr-bridge/          ← Go 中间服务
│   ├── main.go          ← HTTP 路由
│   ├── transcribe.go    ← FunASR WebSocket 客户端
│   └── env.go           ← .env 文件加载
├── speaklow-app/     ← Swift 前端
│   ├── Sources/         ← 15 个 Swift 源文件
│   ├── Info.plist
│   └── Makefile
└── docs/                ← 文档
    ├── PRD.md
    ├── DESIGN.md
    └── HOW_IT_WORKS.md
```

---

## 给其他想自己做的人的建议

1. **先调研**：GitHub 上有大量现成的语音输入项目，找一个合适的 fork 修改，比从零开始快 10 倍。

2. **打日志**：出问题时第一件事是确保你能看到日志。macOS 对未签名应用的日志限制很坑，建议一开始就用文件日志。

3. **不要假设，要验证**：API 返回成功不代表真的成功了。写入数据后要读回来验证。权限状态要实时检查，不要缓存。

4. **分层排查**：录音、格式转换、网络请求、ASR 识别、文字插入——每一层都可能出问题。用 curl 这样的工具逐层验证，定位到具体是哪一层的问题。

5. **向 AI 明确说"不要假设"**：我在调试过程中反复告诉 AI "不要轻易做假设，要验证"。这很关键——AI 会倾向于根据经验猜测原因并直接修改代码，但很多时候猜错了会浪费更多时间。坚持让它先拿到日志证据再下结论。

---

## 我给 AI 的关键提示（Prompt）汇总

以下是整个开发过程中，我给 AI 的几个关键提示，供参考：

### 调研阶段
> "请帮我搜索 10 个以上符合我要求的前端开源框架"

让 AI 广泛搜索，比你自己一个个 Google 快得多。

### 架构决策
> "直接读取 .env，不要用户输入"
> "把 Go 编译成二进制塞进 .app 包里"

在 AI 给你选项时，果断做决策。不要什么都让 AI 决定。

### 补充需求
> "识别完之后自动插入到当前光标位置。如果插入失败，提示用户并复制到剪贴板。"

把你期望的降级策略说清楚，AI 会实现得更好。

### 调试阶段（最重要）
> "你不要做假设，要确保找到核心问题"
> "你不要轻易地做假设，要验证一下"
> "日志打得够多吗？如果没有足够的日志，你最好补上"

这几句话我反复说了好几次。AI 调试时最大的问题是容易猜测原因然后改代码，改了不对再猜，陷入循环。明确告诉它"先拿证据"，效率会高很多。

### 解释阶段
> "我是一个技术小白，请用更加通俗易懂的方式解释"

不懂就问，让 AI 换一种方式解释。它可以用比喻、表格、流程图等各种方式帮你理解。

---

*这篇教程的每一个字，都是用 SpeakLow 语音输入写的。嗯，开玩笑的，但以后可以是真的。*
