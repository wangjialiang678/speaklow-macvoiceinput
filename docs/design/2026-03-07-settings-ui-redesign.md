---
title: "设计方案：SpeakLow 主界面重设计"
date: 2026-03-08
status: approved
audience: human
tags: [design, ui, settings]
---

# SpeakLow 主界面重设计方案

> 日期：2026-03-08
> 状态：APPROVED
> 前置文档：`docs/design/2026-03-06-batch-asr-strategy.md`
> 设计参考：`docs/research/macos-settings-ui-design-reference.md`
> 设计风格：对标 Dato（Sindre Sorhus）— 原生 SwiftUI、单页 Form、HIG 规范

---

## 设计定位

这不是传统的"设置窗口"，而是 SpeakLow 的**主界面**。
核心交互（按住热键说话）不需要 UI，所以这个窗口承担 **状态总览 + 配置 + 操作 + 诊断** 的综合职责。

---

## 一、主界面完整布局

窗口尺寸：minWidth 480pt，高度自适应内容（`.fixedSize(horizontal: false, vertical: true)`）。
单页 Form + `.formStyle(.grouped)`，不分 Tab。
说明文字统一用 Section footer（HIG 规范），不内嵌 `.caption` Text。

```
+---------------------------------------------------+
|  SpeakLow                                          |
+---------------------------------------------------+
|                                                     |
|  +- 状态总览 ------------------------------------+ |
|  |  当前模式：无预览       后台服务：● 运行中       | |
|  |  辅助功能：已授权                               | |
|  |                                                 | |
|  |  今日：识别 12 次 · 2,340 字 · 用时 8 分 32 秒  | |
|  |  平均速度：274 字/分  累计：156 次 · 28,450 字   | |
|  +-----------------------------------------------+ |
|                                                     |
|  +- 通用 ----------------------------------------+ |
|  |  [v] 开机自动启动                               | |
|  +-----------------------------------------------+ |
|                                                     |
|  +- 听写热键 ------------------------------------+ |
|  |  [ Fn / 地球仪键 ] [ 右 Option 键 ] [ F5 键 ]  | |
|  +-----------------------------------------------+ |
|  |  footer: 提示（仅选 Fn 时）：如果按 Fn 会打开   | |
|  |  表情选择器，请前往系统设置 > 键盘，将"按下 fn   | |
|  |  键时"改为"无操作"                              | |
|                                                     |
|  +- 识别模式 ------------------------------------+ |
|  |  [ 无预览 ]  [ 实时预览 ]                       | |
|  +-----------------------------------------------+ |
|  |  footer:                                        | |
|  |  无预览：录完后统一识别，无需后台服务，约 1-2 秒  | |
|  |  实时预览：边说边显示文字，延迟极低，需后台服务   | |
|                                                     |
|  +- AI 文字优化 ---------------------------------+ |
|  |  [v] 启用 AI 优化                               | |
|  |  (启用时显示)                                    | |
|  |  风格：[ 通用 ] [ 商务 ] [ 聊天 ]                | |
|  +-----------------------------------------------+ |
|  |  footer: (根据选中风格动态切换)                   | |
|  |  通用：纠正错字和口语化表达，保持原意              | |
|  |  商务：正式书面风格，适合邮件、文档、汇报          | |
|  |  聊天：轻松自然，适当加 emoji，适合即时通讯       | |
|                                                     |
|  +- 热词 ----------------------------------------+ |
|  |  管理识别时优先识别的专有名词       [编辑热词...]  | |
|  |  当前：98 个热词                                | |
|  |                                                 | |
|  |  (展开后)                                        | |
|  |  +------------------------------------------+  | |
|  |  |  Claude Code                          x  |  | |
|  |  |  Cursor                               x  |  | |
|  |  |  DeepSeek                             x  |  | |
|  |  |  ...（可滚动，最多显示 8 行）              |  | |
|  |  +------------------------------------------+  | |
|  |  [___新热词___]  [添加]                         | |
|  |  共 98 个热词       [在编辑器中打开原始文件]      | |
|  +-----------------------------------------------+ |
|                                                     |
|  +- 后台服务（仅实时预览模式显示）-------------------+ |
|  |  ● 运行中  localhost:18089                      | |
|  |  [检查状态]  [重启服务]  [停止/启动]             | |
|  +-----------------------------------------------+ |
|                                                     |
|  +- 辅助功能权限 --------------------------------+ |
|  |  当 SpeakLow 无法自动插入文字时，可通过重新       | |
|  |  授权来恢复：                                   | |
|  |  1. 点击下方按钮，打开系统辅助功能设置            | |
|  |  2. 在列表中找到 SpeakLow，点击 - 删除           | |
|  |  3. 从安装目录重新添加 SpeakLow 并勾选开关        | |
|  |                                                 | |
|  |  当前位置：/Applications/SpeakLow.app            | |
|  |  [在 Finder 中显示]  [打开辅助功能设置...]        | |
|  +-----------------------------------------------+ |
|                                                     |
|  +- 诊断 ----------------------------------------+ |
|  |  [运行诊断]       [导出诊断日志...]              | |
|  |  [重新运行初始引导...]                           | |
|  |                                                 | |
|  |  (运行诊断后展开结果区域)                         | |
|  |  v  API Key：已配置                              | |
|  |  v  网络连通性：正常                              | |
|  |  v  后台服务：运行中                              | |
|  |  v  麦克风权限：已授权                            | |
|  |  !  辅助功能权限：未授权                          | |
|  |     -> 请重新授权（见上方说明）                    | |
|  |                                                 | |
|  |  -- AI 分析 --                                  | |
|  |  "WebSocket 连接在过去 10 分钟失败了 5 次..."     | |
|  |              [导出诊断日志...]  [关闭]            | |
|  +-----------------------------------------------+ |
|                                                     |
|  -------------------------------------------------  |
|  SpeakLow v0.3.1 (build 42) · 2026-03-08           |
+---------------------------------------------------+
```

---

## 二、各区块详细交互说明

### 2.0 状态总览（新增）

窗口最顶部，类似"仪表盘"，让用户打开窗口就能看到"一切正常"或"哪里有问题"。

**第一行：实时状态**
- 当前模式：无预览 / 实时预览
- 后台服务：● 运行中（绿）/ ● 已停止（红）/ 不显示（无预览模式）
- 辅助功能：已授权 / 未授权（红色文字）

**第二行：使用统计**
- 今日：识别 N 次 · N 字 · 用时 M 分 S 秒
- 平均速度：N 字/分钟
- 累计：N 次 · N 字

**数据存储**（UserDefaults）：

| 字段 | Key | 更新时机 |
|------|-----|---------|
| 今日识别次数 | `stats_today_count` | 每次转写完成 +1 |
| 今日字数 | `stats_today_chars` | 每次转写完成 +text.count |
| 今日录音时长（秒） | `stats_today_duration` | 每次录音结束累加 |
| 累计识别次数 | `stats_total_count` | 同上 |
| 累计字数 | `stats_total_chars` | 同上 |
| 日期标记 | `stats_date` | 跨日自动重置今日计数 |

平均口述速度 = 今日字数 / 今日录音总时长（分钟），实时计算。

### 2.1 通用

| 控件 | 类型 | 绑定 |
|------|------|------|
| 开机自动启动 | Toggle | `appState.launchAtLogin` |

### 2.2 听写热键

Segmented Picker，中文化显示名：
- `Fn / 地球仪键`
- `右 Option 键`
- `F5 键`

Section footer：仅选 Fn 时显示提示文字。

### 2.3 识别模式

Segmented Picker：`[ 无预览 ] [ 实时预览 ]`

Section footer 根据当前选中模式动态显示：
- 无预览：录完后统一识别，无需后台服务，适合网络不稳定或低功耗场景，约 1-2 秒延迟
- 实时预览：边说边实时显示文字，延迟极低，需要运行后台服务

模式切换副作用（已实现）：
- 切到实时预览 → 自动启动后台服务，显示"后台服务"区块
- 切到无预览 → 自动停止后台服务，隐藏"后台服务"区块

### 2.4 AI 文字优化

Toggle + Segmented Picker（启用时显示）。

Section footer 根据当前选中风格动态显示：

| 风格 | footer 文字 |
|------|------------|
| 通用 | 纠正错字和口语化表达，顺通语句，保持你的原意不变 |
| 商务 | 改写为正式书面风格，语气严谨，适合邮件、文档、汇报 |
| 聊天 | 保持轻松自然的语气，适当加入 emoji，适合微信、Slack 等即时通讯 |

### 2.5 热词编辑（新增）

**方案 A（内嵌列表）+ 方案 C（编辑器打开）补充。**

初始状态：
- 显示热词数量 + "编辑热词..."按钮
- 点击展开内嵌 List

展开状态：
- 可滚动列表，最多显示 8 行高度（约 240pt）
- 每行：热词文本 + 右侧 x 删除按钮
- 底部：输入框 + 添加按钮
- 底部链接："在编辑器中打开原始文件"（调用 `NSWorkspace.shared.open(hotwordsFileURL)`）

**热词文件迁移**：
- `Resources/hotwords.txt` 在 `.app` bundle 内只读
- 首次启动时复制到 `~/.config/speaklow/hotwords.txt`
- 后续读写用户目录版本
- `DashScopeClient` 和 `asr-bridge` 的热词加载路径同步更新

### 2.6 后台服务管理（新增）

**显示条件**：`appState.asrMode == .streaming`

状态指示器三态：
- 绿色 ●：运行中
- 红色 ●：已停止
- 黄色 ●：启动中 / 检查中

按钮：

| 按钮 | 调用 | 说明 |
|------|------|------|
| 检查状态 | `TranscriptionService().checkHealth()` | 检查中显示 spinner |
| 重启服务 | `bridgeManager.restart()` | |
| 停止 | `bridgeManager.stop()` | 运行中时显示 |
| 启动 | `bridgeManager.start()` | 已停止时显示 |

### 2.7 辅助功能权限（新增）

固定显示操作指引，步骤：
1. 点击下方按钮，打开系统辅助功能设置
2. 在列表中找到 SpeakLow，点击 - 删除
3. 从安装目录重新添加 SpeakLow 并勾选开关

显示当前安装位置：`Bundle.main.bundlePath`

按钮：
- `[在 Finder 中显示]` → `NSWorkspace.shared.selectFile(Bundle.main.bundlePath, ...)`
- `[打开辅助功能设置...]` → `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`

### 2.8 诊断（增强）

三个按钮：
- **运行诊断** — 执行自检流程（见第三节）
- **导出诊断日志...** — 现有 `DiagnosticExporter.exportWithSavePanel()`
- **重新运行初始引导...** — `appState.hasCompletedSetup = false` + `post(.showSetup)`

### 2.9 版本信息

窗口底部，Form 外，水平居中，`.font(.caption)` + `.foregroundStyle(.tertiary)`：

```
SpeakLow v0.3.1 (build 42) · 2026-03-08
```

数据来源：
- `CFBundleShortVersionString` — 版本号
- `CFBundleVersion` — 构建号
- `BuildDate` — Makefile 构建时写入 Info.plist

---

## 三、运行诊断详细流程

### 3.1 触发

点击"运行诊断" → 按钮变 spinner → 执行检查 → 完成后在诊断区块内展开结果。

### 3.2 检查项与顺序

诊断按以下顺序执行，API Key 和网络作为前置检查：

| 顺序 | 检查项 | 检查逻辑 | 预期耗时 |
|------|--------|---------|---------|
| 1 | API Key | 检查 API Key 是否已加载（EnvLoader） | <0.1s |
| 2 | 网络连通性 | TCP 连接 `dashscope.aliyuncs.com:443` | 1-3s |
| 3 | 后台服务 | `GET /health`（仅 streaming 模式） | <1s |
| 4 | 麦克风权限 | `AVCaptureDevice.authorizationStatus` | <0.1s |
| 5 | 辅助功能权限 | `AXIsProcessTrusted()` | <0.1s |
| 6 | 日志分析 | 读 `SpeakLow.log` 最后 200 行，检测 ERROR | <0.1s |
| 7 | AI 日志分析 | API Key 正常 → 日志摘要发送 qwen-flash | 2-5s |

### 3.3 判定与自动修复

**API Key**：
- PASS：`EnvLoader.loadDashScopeAPIKey()` 返回非空
- FAIL：提示"未找到 API Key，请确认 ~/.config/speaklow/.env 中配置了 DASHSCOPE_API_KEY"
- API Key 失败时跳过 AI 日志分析（第 7 步）

**网络连通性**：
- PASS：TCP 连接成功
- FAIL：提示"无法连接 DashScope API，请检查网络或代理设置"
- 网络失败时跳过 AI 日志分析

**后台服务**（仅 streaming 模式）：
- PASS：HTTP 200 + `status:ok`
- FAIL：自动调用 `bridgeManager.restart()`，等 5 秒后复查
- 修复成功：显示"已自动重启后台服务 ✓"
- 修复失败：提示导出诊断日志

**权限**：
- PASS / WARN（不报错，给引导链接到辅助功能权限区块）

**日志分析**（本地正则匹配）：
- `DASHSCOPE_API_KEY not found` → 提示检查 `.env`
- `WS connect failed` → 结合网络检查结果
- `连续重启超过上限` → 提示 API Key 配置问题
- 统计最近 ERROR 数量和最后一条内容

**AI 日志分析**（前提：API Key 正常 + 网络正常）：
- 将最近 50 行日志 + 系统信息发送 qwen-flash
- Prompt：识别异常模式，给出 1-3 条人话建议
- 结果分类：已知问题 → 给出修复建议；未知问题 → 提示导出诊断日志
- 调用失败 → 静默跳过，不影响其他结果

### 3.4 结果展示

在诊断区块内展开：

```
+- 诊断结果 ----------------------------------------+
|  v  API Key：已配置                                 |
|  v  网络连通性：正常                                |
|  v  后台服务：运行中                                |
|  v  麦克风权限：已授权                              |
|  !  辅助功能权限：未授权                            |
|     -> 请重新授权（见上方"辅助功能权限"说明）         |
|                                                     |
|  -- 日志分析 --                                     |
|  发现 3 条错误，最近一条：                           |
|  [2026-03-08] WS connect failed: connection refused |
|                                                     |
|  -- AI 分析 --                                      |
|  "WebSocket 连接失败与网络波动有关，建议：            |
|   1. 检查是否开启了 VPN                              |
|   2. 尝试切换到无预览模式确认 REST API 是否正常"      |
|                                                     |
|              [导出诊断日志...]  [关闭]               |
+-------------------------------------------------+
```

### 3.5 新增代码

```swift
// 新文件：Sources/DiagnosticRunner.swift
struct DiagnosticResult {
    enum Status { case pass, warn, fail, skipped }
    let name: String
    let status: Status
    let detail: String
    let autoFixed: Bool
    let suggestion: String?
}

class DiagnosticRunner {
    func run(asrMode: ASRMode, bridgeManager: ASRBridgeManager?) async -> [DiagnosticResult]
    private func checkAPIKey() -> DiagnosticResult
    private func checkNetwork() async -> DiagnosticResult
    private func checkBridgeHealth(...) async -> DiagnosticResult
    private func checkPermissions() -> [DiagnosticResult]
    private func analyzeRecentLogs() -> DiagnosticResult
    private func aiAnalyzeLogs(summary: String) async -> DiagnosticResult?
}
```

---

## 四、文件改动清单

| 文件 | 操作 | 内容 |
|------|------|------|
| `Sources/SettingsView.swift` | 重构 | 全面重写，新增状态总览 + 所有区块 |
| `Sources/TranscriptionStrategy.swift` | 修改 | `ASRMode.batch.displayName` "标准" -> "无预览" |
| `Sources/HotkeyManager.swift` | 修改 | 热键显示名中文化 |
| `Sources/AppState.swift` | 修改 | 新增使用统计属性和累加逻辑 |
| `Sources/DiagnosticRunner.swift` | **新增** | 运行诊断逻辑（含 AI 分析） |
| `Sources/HotwordEditor.swift` | **新增** | 热词编辑 UI（方案 A + C） |
| `Sources/DiagnosticExporter.swift` | 不改 | 直接复用 |
| `Makefile` | 修改 | 构建时写入 `BuildDate` 到 Info.plist |

---

## 五、已确认决策

| 决策 | 结论 |
|------|------|
| 热词编辑方案 | 方案 A（内嵌列表）+ 方案 C（编辑器打开原始文件）补充 |
| 热词文件存储 | 迁移到 `~/.config/speaklow/hotwords.txt`，bundle 版为初始模板 |
| AI 日志分析 | 做。前提：API Key 正常 + 网络正常时才执行 |
| 窗口布局 | 单页 Form 滚动，不分 Tab |
| 识别模式控件 | Segmented Control |
| 菜单栏 | 保持现状不改 |
| API Key 管理 | 不在界面展示，仅诊断时检查 |
| 快速操作区 | 不做 |
| 麦克风输入设备 | 删除 |
| 设计风格 | 对标 Dato — 原生 SwiftUI，HIG 规范 |

---

## 六、实现优先级

| 优先级 | 区块 | 难度 |
|--------|------|------|
| P0 | 识别模式重命名 + 风格描述优化 + 删除麦克风 + 中文化 | 低 |
| P0 | 状态总览（模式/服务/权限状态 + 使用统计） | 中 |
| P1 | 后台服务管理 + 辅助功能权限 + 版本信息 | 中 |
| P1 | Section footer 规范化（HIG） | 低 |
| P2 | 热词编辑（方案 A + C） | 中 |
| P2 | 运行诊断（含 AI 分析） | 高 |
