# macOS 设置窗口 UI 设计参考

**日期**: 2026-03-07
**目标**: 为 SpeakLow 设置窗口重新设计提供设计依据

---

## 一、Apple Human Interface Guidelines 核心摘要

### 1.1 Settings 窗口通用规范

来源：[Apple HIG - Settings](https://developer.apple.com/design/human-interface-guidelines/settings)

**窗口行为**
- 快捷键：`⌘+,`（强制要求）
- 关闭方式：Escape 或 `⌘+.`
- 只有关闭按钮（红色）可用；最小化（黄）和最大化（绿）按钮通常禁用
- 首次打开时居中显示（`NSWindow.center()`）；后续打开恢复上次位置
- 多 Tab 时记住上次选中的 Tab

**交互模式（Modeless Design）**
- 不需要 Save / Cancel / Apply 按钮
- 设置立即生效，自动持久化
- 这是 macOS 设置窗口的标准模式，用户期望改动即时生效

**Tab 工具栏（Preference Toolbar）**
- 必须使用 `NSWindow.toolbarStyle = .preference`
- 每个 Tab 必须同时提供图标和标签文字（无障碍要求）
- 推荐使用 SF Symbols 风格的图标
- 常规顺序：General 放第一位，Advanced 放最后

**布局间距（精确数值）**
- 内容距窗口边缘：**20pt** 外边距
- 控件之间水平间距：**8pt**，垂直间距：**6pt**
- Section 标题标签：13pt Regular 系统字体，右对齐，以冒号结尾
- 描述说明文字：**11pt**，secondary label 颜色
- 超链接：蓝色，无下划线

**动画**
- 切换 Tab 时使用缓动动画平滑调整窗口尺寸
- 顺序：隐藏旧面板 → 调整尺寸 → 显示新面板
- 必须遵守「减少动画」无障碍设置

### 1.2 macOS 菜单栏 Extra 设计规范

来源：[Bjango - Designing Menu Bar Extras](https://bjango.com/articles/designingmenubarextras/)

**图标尺寸**
- 菜单栏工作区固定高度 **22pt**，图标不能超过此高度
- 推荐使用 **16×16pt** 圆形格式，与系统图标视觉重量一致
- 历史：macOS Big Sur 起菜单栏高度固定为 **24pt**（新款 MacBook Pro 带刘海的为 **37pt**）

**图标颜色**
- 优先使用 Template Image（模板图）：仅 alpha 通道，自动适配深色/浅色模式
- 禁用状态可用 35% 透明度表示
- 允许彩色图标，但 Template 图集成更原生

**无障碍**
- 测试「减少透明度」选项下的外观（菜单栏变为深灰/浅灰实色背景）

### 1.3 SwiftUI Form 设计

来源：[Apple - Form Documentation](https://developer.apple.com/documentation/swiftui/form)、[GroupedFormStyle](https://developer.apple.com/documentation/swiftui/groupedformstyle)

**推荐的 macOS 设置窗口写法**：
```swift
Form {
    Section("通用") {
        // Picker / Toggle / LabeledContent
    }
    Section("高级") {
        // ...
    }
}
.formStyle(.grouped)
.frame(minWidth: 480)
```

**关键注意点**
- macOS 默认 Form style 是 `.columns`，设置窗口应显式改为 `.grouped`
- `.grouped` 风格自动产生 System Settings 式的分组视觉
- 可以用 `LabeledContent` 实现标签-控件两列对齐
- `.windowResizability(.contentSize)` 让窗口自适应内容大小，不允许随意拖拽
- 使用 `Section(header:footer:)` 在组底部放置说明文字，比在组内放 `.caption` 更规范

---

## 二、优秀设计案例分析

### 2.1 Raycast

**官网**: https://www.raycast.com/

**设置窗口特点**
- 宽幅窗口（约 800-1000pt），左侧导航列表 + 右侧内容区（Master-Detail 布局）
- 适合扩展数量多、设置项复杂的工具
- 每个扩展有独立配置面板，统一在 Extensions Tab 管理
- 配色克制：背景 vibrancy 材质，强调色仅用于选中状态
- 支持偏好导出/导入（适合多设备用户）

**启示**：Raycast 设置窗口属于「重量级」工具类，SpeakLow 不需要模仿其复杂程度，但其「立即生效」和「分组清晰」的理念值得借鉴。

### 2.2 CleanShot X

**官网**: https://cleanshot.com/

**设置窗口特点**
- 中等宽度（约 500-600pt），Toolbar-Tabs 导航
- 每个 Tab 内容密度适中，不超过一屏高
- 大量使用 Toggle + 简短说明文字的组合
- 快捷键配置采用「录制按键」交互，直觉操作
- 图标：SF Symbols + 自定义风格保持一致

**启示**：CleanShot X 的设置窗口是「中等复杂度」工具的好范本，其 Tab 数量（约 5-6 个）和单 Tab 内容量（约 6-10 项）适合作为 SpeakLow 参考基准。

### 2.3 Dato

**开发者**: Sindre Sorhus | https://sindresorhus.com/dato

**设计特点**
- 严格遵循 Apple HIG，原生感极强
- 设置窗口使用 Toolbar-Tabs，每 Tab 内容高度约 300-400pt
- 纯 SwiftUI 实现，使用 Sindre 的开源 [Settings 包](https://github.com/sindresorhus/Settings)
- 颜色方案完全跟随系统 accent color，不做自定义
- 描述文字统一 11pt secondary 色

**Sindre Sorhus 设计理念**（来源: [Indie Dev Monday 访谈](https://indiedevmonday.com/issue-53)）
> "专注做一件事，做到最好。严格遵守 Apple HIG，原生即是最好的设计。"

**启示**：对于工具类 macOS app，「像系统自带一样」是最高评价。Dato 证明了不需要花哨设计，遵循 HIG 本身就是优秀设计。

### 2.4 SuperWhisper（同类竞品）

**官网**: https://superwhisper.com/

**设置特点**
- 菜单栏工具，设置窗口中等复杂度
- 分为 General / Models / Modes / Hotkeys 等 Tab
- 录音模式选择使用卡片式 UI（大图标+描述），视觉上比 Segmented 更清晰
- API Key 输入独立成一个 Tab，降低普通用户的认知负担
- 状态指示（如 AI 模型下载进度）内嵌在对应设置项中，不弹新窗口

**对 SpeakLow 的直接启示**：
- 「识别模式」选择可以考虑用卡片式而非 Segmented Control
- API Key 管理可以从主设置视图独立出来

### 2.5 Apple Design Awards 2024/2025 参考

来源：[2024 获奖名单](https://developer.apple.com/design/awards/2024/)、[2025 获奖名单](https://developer.apple.com/design/awards/)

与设置窗口设计最相关的获奖原则：
- **Interaction 类奖项**：强调每个交互都有清晰反馈，状态变化即时可见
- **Visuals and Graphics 类奖项**：强调视觉一致性，不混用不同 UI 风格
- **Inclusivity 类奖项**：强调无障碍设计（VoiceOver、动态字体、减少动画）

---

## 三、设置窗口设计现代趋势

### 3.1 窗口尺寸趋势

| 类型 | 宽度 | 高度 | 典型案例 |
|------|------|------|--------|
| 轻量工具 | 400-480pt | 按内容自适应 | Lungo、Pockity |
| 中等工具 | 480-600pt | 400-600pt | CleanShot X、Dato |
| 重量工具 | 700-1000pt | 600pt+ | Raycast、Alfred |

SpeakLow 属于「中等工具」，建议 **minWidth: 480pt**，高度自适应内容。

### 3.2 信息密度 vs. 可读性

**高密度（不推荐用于 SpeakLow）**
- 每 Section 超过 6 项控件
- 无说明文字，依赖用户探索
- 控件紧密堆叠，间距小于 6pt

**低密度（推荐方向）**
- 每 Section 3-5 项控件为宜
- 重要设置项附加 footer 说明（`.font(.caption)` + `.foregroundStyle(.secondary)`）
- 危险操作（如重置）单独放在底部 Section

**平衡原则**：「能用一屏展示完最好，滚动超过 1.5 屏高说明需要重新分 Tab」

### 3.3 SwiftUI Form 已知坑

- `Form + .formStyle(.grouped)` 顶部有额外 padding，需用 `.padding(.top, -20)` 调整
- `Picker(.segmented)` 在 `.grouped` Form 中视觉较好
- `Toggle` 默认靠右，在 `.grouped` Form 中自动对齐
- 窗口高度不要硬编码，用 `.fixedSize(horizontal: false, vertical: true)` 让内容决定高度

---

## 四、当前 SpeakLow SettingsView 现状分析

现有代码（`speaklow-app/Sources/SettingsView.swift`）问题：

1. **混用中英文**：Section 标题有英文（"Push-to-Talk Key", "Microphone", "Startup"），也有中文（"识别模式", "AI 文字优化"），不统一
2. **窗口尺寸过小**：`minWidth: 400` 偏小，`.grouped` Form 在此宽度下显示拥挤
3. **多余 .padding()**：`Form + .formStyle(.grouped)` 外层不需要再加 `.padding()`，会导致双重内边距
4. **ASR Bridge 状态混在设置里**：状态监控信息（健康检查）放在设置窗口中不太合适，应移至菜单栏弹出窗口或独立状态区域
5. **条件式显示不清晰**：`if appState.llmRefineEnabled { ... }` 内容条件渲染，导致窗口高度跳变，体验不佳

---

## 五、对 SpeakLow 设置窗口重设计的建议

### 建议 1：统一语言，全部改为中文

设置窗口面向的是中文用户，所有 Section 标题、控件标签、说明文字统一中文。

### 建议 2：调整窗口尺寸

```swift
.frame(minWidth: 480, maxWidth: 560)
.fixedSize(horizontal: false, vertical: true)
```

480pt 是中等工具设置窗口的最小推荐宽度；移除固定高度，让内容决定高度。

### 建议 3：增加 Tab 分组（若设置项增加）

当前设置项约 6-7 个，勉强一个页面放得下。若未来增加 API Key 管理、热词管理等，建议按以下 Tab 分组：

| Tab | 图标（SF Symbols） | 内容 |
|-----|-----------------|------|
| 通用 | `gearshape` | 热键、麦克风、开机自启 |
| 识别 | `waveform` | ASR 模式、Bridge 状态 |
| 优化 | `sparkles` | AI 优化开关、风格选择 |
| 账号 | `key` | API Key 管理 |

### 建议 4：Section footer 替代内嵌 caption

当前写法（不推荐）：
```swift
Section("识别模式") {
    Picker(...)
    Text("说明文字").font(.caption) // 混在 Section 内部
}
```

推荐写法：
```swift
Section {
    Picker(...)
} header: {
    Text("识别模式")
} footer: {
    Text("标准：录完后一次性识别；实时预览：边说边显示（需后台服务）")
}
```

### 建议 5：「识别模式」改用描述性选择控件

Segmented Control 对「标准 / 实时预览」描述不够直观，建议改用带图标和描述的卡片式选择，或至少用带说明的 Picker（`.pickerStyle(.inline)`）。

### 建议 6：ASR Bridge 状态移出设置窗口

ASR Bridge 的健康检查是「运行状态」而非「配置项」，更适合放在：
- 菜单栏点击弹出的 MenuBarView 中（始终可见）
- 或作为菜单栏图标的 badge/tooltip 提示

### 建议 7：遵循 Modeless 原则，去除多余提示

macOS 设置窗口不需要提示用户「已保存」，改动即生效。若有需要重启生效的设置，用 footer 文字注明即可，不要弹 Alert。

### 建议 8：无障碍和减少动画支持

- 确保所有控件有 `.accessibilityLabel`
- Tab 切换动画使用 `withAnimation(.easeInOut)` 并检查 `@Environment(\.accessibilityReduceMotion)`

---

## 六、参考资料

- [Apple HIG - Settings](https://developer.apple.com/design/human-interface-guidelines/settings)
- [Apple HIG - Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [Apple HIG - The Menu Bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar)
- [Apple HIG - Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
- [Apple HIG - SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
- [Bjango - Designing Menu Bar Extras](https://bjango.com/articles/designingmenubarextras/)
- [macOS Settings Window Guidelines (usagimaru)](https://zenn.dev/usagimaru/articles/b2a328775124ef?locale=en)
- [Sindre Sorhus - Settings Package](https://github.com/sindresorhus/Settings)
- [Tailor macOS windows with SwiftUI - WWDC24](https://developer.apple.com/videos/play/wwdc2024/10148/)
- [SwiftUI for Mac 2024 - TrozWare](https://troz.net/post/2024/swiftui-mac-2024/)
- [Apple Design Awards 2024](https://developer.apple.com/design/awards/2024/)
- [Apple Design Awards 2025](https://developer.apple.com/design/awards/)
- [SuperWhisper Settings Documentation](https://superwhisper.com/docs/get-started/settings)
