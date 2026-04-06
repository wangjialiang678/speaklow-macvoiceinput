---
title: "设计方案：SpeakLow 设置界面重设计"
date: 2026-03-08
updated: 2026-04-06
status: implemented
audience: human
tags: [design, ui, settings]
---

# SpeakLow 设置界面重设计方案

> 日期：2026-03-08
> 更新：2026-04-06（记录实际实现）
> 状态：**IMPLEMENTED**
> 前置文档：`docs/design/2026-03-06-batch-asr-strategy.md`
> 设计参考：`docs/research/macos-settings-ui-design-reference.md`

---

## 设计定位

这不是传统的"设置窗口"，而是 SpeakLow 的**主界面**。
核心交互（按住热键说话）不需要 UI，所以这个窗口承担 **状态总览 + 配置 + 操作 + 诊断** 的综合职责。

---

## 一、最终实现布局

### 整体结构

窗口采用**左侧边栏 + 右侧内容区**的二栏布局，对标 macOS 系统偏好设置风格。

- 窗口宽度：固定 600pt
- 窗口高度：可调整，最小 480pt，idealHeight 780pt
- 底部版本信息：固定在右侧内容区底部（Form 外，不随滚动移动）

```
+-------+----------------------------------------------+
|       |  [内容区：随 Tab 切换]                        |
| 左侧  |                                               |
| 导航  |  根据选中 Tab 渲染对应 Form                    |
| 栏    |                                               |
| 130pt |                                               |
|       +----------------------------------------------+
|       |  SpeakLow v0.3.1 (build 42) · 2026-03-08    |
+-------+----------------------------------------------+
```

### 五个 Tab

| Tab | 图标 | 内容 |
|-----|------|------|
| 通用 | `gearshape` | 状态总览、开机启动、热键选择 |
| 识别 | `waveform` | ASR 模式、AI 优化、后台服务管理 |
| 用户词典 | `text.book.closed` | 热词内嵌编辑器 |
| 密钥 | `key` | API Key 输入、百炼平台引导、配置文件位置 |
| 高级 | `wrench.and.screwdriver` | 辅助功能重授权、诊断工具 |

---

## 二、左侧导航栏设计

### 关键实现决策

**使用自定义 VStack + Label，而非 List**：

- macOS `List` 在 Settings 场景下行间距和选中样式难以精确控制
- 改为 `VStack(alignment: .leading, spacing: 2)` + `ForEach`，每个 Tab 项手动渲染

**全区域可点击（`.contentShape(Rectangle())`）**：

- SwiftUI 默认只有文字/图标部分响应点击，空白区域无效
- 每个 Tab 行添加 `.contentShape(Rectangle())` 确保整行可点击
- 这是 macOS 侧边栏 UX 的关键细节，不加会导致用户点击行尾空白区域无反应

**选中样式**：圆角矩形背景，`accentColor.opacity(0.2)`，选中时 `.primary`，未选中时 `.secondary`

```swift
.contentShape(Rectangle())
.onTapGesture { selectedTab = tab }
```

### Tab 切换支持外部触发

通过 `NotificationCenter` 接收 `"switchSettingsTab"` 通知，允许其他模块（如启动 toast 点击）直接跳到指定 Tab：

```swift
.onReceive(NotificationCenter.default.publisher(for: .init("switchSettingsTab"))) { notif in
    if let tab = notif.userInfo?["tab"] as? String { ... }
}
```

---

## 三、各 Tab 详细说明

### 3.1 通用 Tab

**状态总览（StatusOverviewSection）**：

放在通用 Tab 最顶部，使用 `LabeledContent` 显示运行状态：

| 字段 | 显示条件 | 内容 |
|------|---------|------|
| 当前模式 | 始终 | `asrMode.displayName` |
| 后台服务 | 仅 streaming 模式 | 绿/红指示点 + 运行中/已停止 |
| 辅助功能 | 始终 | 已授权（灰）/ 未授权（红） |
| 今日 | `statsTodayCount > 0` | 识别 N 次 · N 字 · 用时 M 分 S 秒 |
| 平均速度 | 同上 | N 字/分钟 |
| 累计 | `statsTotalCount > 0` | N 次 · N 字 |

**通用设置**：开机自动启动 Toggle

**听写热键**：Segmented Picker（`Fn / 地球仪键` / `右 Option 键` / `F5 键`）

热键说明文字处理：
- 选中 Fn 时，在 Section 内部添加 `Text(...)` 提示（`.font(.footnote).foregroundStyle(.orange)`）
- **不使用 `Section footer:` 参数**，原因见第四节

### 3.2 识别 Tab

**识别模式**：Segmented Picker（批量 / 流式）

模式说明文字同样内嵌在 Section 内，用 `switch appState.asrMode` 动态切换文字内容。

**AI 文字优化**：Toggle + 风格 Segmented Picker（启用时显示）

风格说明同样内嵌 Text，随选中风格动态切换。

**后台服务管理**（仅 streaming 模式显示，`if appState.asrMode == .streaming`）：
- 状态指示：三态（绿色运行中 / 红色已停止 / 黄色检查中）
- 按钮：检查状态、重启服务、停止服务/启动服务（互斥显示）

### 3.3 用户词典 Tab

嵌入 `HotwordEditorView(standalone: true)`，在 Section 内展示完整的热词编辑功能：
- 热词列表（可滚动）
- 添加/删除
- "已生效"状态反馈（热词修改并重载后显示）
- "在编辑器中打开原始文件"外部编辑器入口

热词文件路径：`~/.config/speaklow/hotwords.txt`（用户目录版本优先，bundle 版为初始模板）

### 3.4 密钥 Tab

三个 Section：

**API Key Section**：
- 说明文字：介绍百炼平台
- 输入框：空时显示 placeholder `sk-...`（TextField），有内容时自动切换为 SecureField 保护密钥
- 保存按钮：触发验证 + 写入文件 + 刷新运行态客户端
- 状态指示（`APIKeyStatus` 枚举）：未知/验证中/有效/无效(含原因)/已保存

**验证流程**：调用 DashScope OpenAI 兼容模式的 `/models` 接口（轻量，无计费），根据 HTTP 状态码区分：401 无效 / 403 无权限 / 200 通过。

**获取 API Key Section**：
- 步骤引导文字（三步：注册 → 创建 Key → 粘贴）
- "打开百炼平台控制台"按钮（`https://bailian.console.aliyun.com/`）
- 警告提示：需开通模型服务、Coding Plan 的 Key 不可用

**配置文件 Section**：
- 显示文件路径 `~/.config/speaklow/.env`（可选中复制）
- "在 Finder 中显示"按钮

**保存逻辑**：读取已有 `.env` 文件内容，替换 `DASHSCOPE_API_KEY` 行（或追加），保存后调用 `DashScopeClient.shared.reloadAPIKey()` 刷新运行态。

### 3.5 高级 Tab

**辅助功能重授权 Section**：

固定显示三步操作指引 + 当前安装路径（`.font(.caption2).textSelection(.enabled)`）。

关键实现：Section 使用了 `} header: { Text("重新授权辅助功能") }` 的 trailing closure 语法，说明内容和按钮都在 Section body 的 `VStack` 中，而非用 footer。

**诊断 Section**：
- 按钮行：运行诊断（含 spinner）+ 导出诊断日志
- 重新运行初始引导按钮
- 诊断结果列表（运行后展开，含状态图标 + 详情 + 建议 + 自动修复标记）
- 结果区底部：导出诊断日志 + 关闭按钮

---

## 四、关键设计决策

### 4.1 侧边栏而非单页 Form

**原始方案**：单页 Form + `.formStyle(.grouped)`，对标 Dato

**实际实现**：左侧边栏 + 五 Tab

**决策原因**：
- 功能增加后（新增密钥 Tab、用户词典 Tab），单页滚动内容过长，不利于快速导航
- 密钥配置需要独立页面提供足够说明空间
- 侧边栏模式在 macOS 设置类 app 中更易发现和切换

### 4.2 Footer 文字改为 Section 内部 Text

**原始方案**：使用 `Section("标题") { ... } footer: { Text("说明") }` HIG 标准写法

**实际实现**：说明文字作为 Section 内的第一个或最后一个 `Text(...)` 子视图

**决策原因**：SwiftUI `.formStyle(.grouped)` 的 `footer:` 参数存在对齐 bug——在某些 macOS 版本下 footer 文字的缩进与 Section 内容不一致，视觉上错位。直接在 Section content 内放 Text 更可控，`.font(.footnote).foregroundStyle(.secondary)` 样式与 footer 视觉效果相近。

### 4.3 窗口可调整大小

**原始方案**：`.fixedSize(horizontal: false, vertical: true)` 高度自适应

**实际实现**：固定宽度 600pt，高度可在 480pt 到无限之间调整

**决策原因**：
- 热词 Tab 内容量不确定，固定高度会导致截断
- 诊断结果展开后需要更多空间
- idealHeight 780pt 作为默认打开高度，用户可自行调整

### 4.4 版本信息位置

**原始方案**：放在 Form 外最底部，水平居中

**实际实现**：固定在右侧内容区底部（HStack 的 VStack 末尾），Tab 切换时始终可见

**决策原因**：作为常驻底部信息，任何 Tab 下都应可见，不随 Form 内容滚动消失。

---

## 五、文件改动清单（已实现）

| 文件 | 操作 | 内容 |
|------|------|------|
| `Sources/SettingsView.swift` | 重构 | 全面重写，侧边栏 + 五 Tab 结构 |
| `Sources/HotwordEditor.swift` | 新增 | 热词内嵌编辑 UI，含自动重载和状态反馈 |
| `Sources/DiagnosticRunner.swift` | 新增 | 运行诊断逻辑（含 AI 日志分析） |
| `Sources/DiagnosticExporter.swift` | 复用 | 导出诊断日志（未改） |
| `Sources/TranscriptionStrategy.swift` | 修改 | `ASRMode` 显示名，`ASRMode.allCases` |
| `Sources/AppState.swift` | 修改 | 使用统计属性（今日/累计）、`hasAccessibility` |

---

## 六、与原始方案的差异对比

| 设计点 | 原始方案 | 实际实现 |
|--------|---------|---------|
| 整体布局 | 单页 Form 滚动 | 左侧边栏 + 五 Tab |
| 窗口高度 | `.fixedSize` 自适应 | 可调整，480pt 起 |
| Section footer | `Section { } footer: { }` | 内嵌 Text（避免对齐 bug） |
| API Key 管理 | 不在界面展示，仅诊断检查 | 独立"密钥" Tab，完整管理 UI |
| 热词编辑 | 方案 A + C（展开列表 + 外部编辑器） | 独立"用户词典" Tab，HotwordEditorView |
| 辅助功能权限 | 独立 Section | 移入"高级" Tab |
| 诊断 | 独立 Section | 移入"高级" Tab |
| 品牌名称 | DashScope | 百炼平台（原 DashScope 灵积已迁移） |
