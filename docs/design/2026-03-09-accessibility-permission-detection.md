---
title: "macOS 辅助功能权限检测方案"
date: 2026-03-09
status: implemented
audience: both
tags: [accessibility, permission, CGEvent, text-insertion]
---

# macOS 辅助功能权限检测方案

## 背景

SpeakLow 通过 CGEvent 发送 `Cmd+V` 将识别文本粘贴到目标应用。此操作依赖 macOS 辅助功能（Accessibility）权限。

## 问题

macOS 的 TCC（Transparency, Consent, and Control）权限系统存在一个陷阱：**权限条目可能与运行时状态不一致（stale）**。

### 三种权限状态

| 状态 | `AXIsProcessTrusted()` | CGEvent 实际发送 | 用户感知 |
|------|----------------------|----------------|---------|
| 未授权 | false | 失败 | 可以检测，弹窗引导 |
| 已授权 | true | 成功 | 正常工作 |
| **Stale（权限失效但条目残留）** | **true** | **静默丢弃** | **无任何提示，文本消失** |

### Stale 状态的触发条件

- **开发者重编译**：`make all` 产生新二进制，ad-hoc 代码签名变化
- **macOS 大版本升级**：可能重置 TCC 数据库
- **App 签名变更**：更换 Developer ID 或证书过期重签

### 为什么 `AXIsProcessTrusted()` 不可靠

`AXIsProcessTrusted()` 查询 TCC 数据库中的静态条目。当条目存在时返回 true，但 macOS 在实际执行 CGEvent 操作时会做**运行时代码签名验证**。如果二进制的签名与 TCC 条目记录的不匹配，事件被静默丢弃——没有错误码，没有异常，就像从未发生过。

`AXIsProcessTrustedWithOptions(prompt: true)` 同样不可靠：它在 TCC 条目存在时不会弹窗。

## 解决方案

### 核心思路：用 `CGEvent.tapCreate()` 做运行时验证

`CGEvent.tapCreate()` 创建事件监听器时，macOS 会执行**与 CGEvent 发送相同的运行时代码签名验证**。如果权限 stale，它返回 `nil`。

```swift
private func isCGEventPermissionWorking() -> Bool {
    let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
        callback: { _, _, event, _ in Unmanaged.passRetained(event) },
        userInfo: nil
    )
    if let tap = tap {
        CFMachPortInvalidate(tap)  // 立即释放，只做探测
        return true
    }
    return false
}
```

### 启动时检测流程

```
App 启动
  ├── AXIsProcessTrusted() == false
  │     → 弹系统权限对话框（首次安装 / 权限被撤销）
  │
  └── AXIsProcessTrusted() == true
        ├── CGEvent.tapCreate() 成功
        │     → 权限正常，无操作
        │
        └── CGEvent.tapCreate() 失败
              → 权限 stale → 打开系统设置辅助功能页面
```

### 各场景用户体验

| 场景 | 检测结果 | 行为 | 对用户的影响 |
|------|---------|------|-------------|
| 首次安装 | AX=false | 系统弹权限对话框 | 正常引导 |
| 日常重启 | AX=true, tap=OK | 无操作 | 零打扰 |
| 正式签名的 App 更新 | AX=true, tap=OK | 无操作 | 零打扰 |
| 开发者重编译 | AX=true, tap=nil | 打开系统设置 | 启动时就提示，不浪费第一次录音 |
| macOS 升级重置 | AX=false | 系统弹权限对话框 | 正常引导 |
| 用户手动撤销 | AX=false | 系统弹权限对话框 | 正常引导 |

### 插入失败时的兜底

即使启动检测未覆盖的边缘情况，`TextInserter` 的三层降级仍然有效：

1. **AX 直接写入** → 读回验证（Electron 返回 success 但不生效）
2. **Clipboard + Cmd+V** → 250ms 后 AX 值长度对比验证
3. **仅复制到剪贴板** → 弹出文字结果面板 + 打开系统设置引导

### 粘贴验证的改进

`AXWebArea`（VS Code webview 等）不支持 `kAXValueAttribute` 读取，始终返回空字符串。粘贴前后都是 0 会被误判为"值没变化 → 粘贴失败"。

修复：只在 `beforeLen > 0` 时才做失败判断。`beforeLen == 0 && afterLen == 0` 视为不确定，假定粘贴成功。

## 关键代码位置

- `AppState.checkAccessibilityOnLaunch()` — 启动时权限检测
- `AppState.isCGEventPermissionWorking()` — CGEvent.tapCreate 探测
- `AppState.openAccessibilitySettings()` — 引导用户修复权限
- `TextInserter.insert()` — 三层降级插入 + 验证
- `TextInserter.pasteViaClipboard()` — 粘贴验证逻辑
- `AppDelegate.applicationDidFinishLaunching()` — 调用启动检测

## 历史演进

1. **v0.1**：`AXIsProcessTrusted()` 阻塞式检查 → 重编译后反复弹窗
2. **v0.4**：移除阻塞检查，改为插入时降级 → 不再弹窗但第一次必失败
3. **v0.5+**（本方案）：`CGEvent.tapCreate()` 运行时验证 → 启动时准确检测，不误报

## 注意事项

- `CGEvent.tapCreate()` 创建的 tap 必须立即 `CFMachPortInvalidate()` 释放
- 正式签名发布的 App 更新（同一 Developer ID）不会导致权限 stale
- 开发时每次 `make all` 都会改变 ad-hoc 签名，需要在系统设置中 toggle 权限
