# 远程诊断日志增强设计

**日期**: 2026-03-06
**状态**: PENDING
**目标**: 让朋友试用 DMG 后，能一键打包日志发给我远程排障

## 问题分析

当前日志系统在远程诊断场景下有三个致命盲区：

1. **Go bridge 日志完全易失** — 写 stdout，被 ASRBridgeManager 的 pipe 捕获后走 os_log，但 unsigned app 的 unified log 不可见。Bridge 崩溃后无任何痕迹。
2. **流式识别中间状态无日志** — partial/final 何时到达、stall 检测何时触发、WebSocket close 原因均缺失。
3. **无日志打包/导出功能** — 用户无法方便地收集和发送日志。

## 方案设计

### 模块 A: Go Bridge 文件日志（asr-bridge/）

**改动文件**: `asr-bridge/main.go`

在 `main()` 启动时初始化文件日志，与 stdout 双写：
- 日志路径: `~/Library/Logs/SpeakLow-bridge.log`
- 使用 `io.MultiWriter(os.Stdout, logFile)` 同时输出到 stdout 和文件
- 日志轮转: 启动时检查文件大小，>5MB 则重命名为 `.1.log`（保留 1 份旧日志）
- 格式: Go 标准 `log` 已有时间戳，无需额外处理

```go
func initFileLog() {
    logDir := filepath.Join(os.Getenv("HOME"), "Library", "Logs")
    logPath := filepath.Join(logDir, "SpeakLow-bridge.log")

    // 简单轮转: >5MB 重命名为 .1.log
    if info, err := os.Stat(logPath); err == nil && info.Size() > 5*1024*1024 {
        os.Rename(logPath, logPath+".1.log")  // 覆盖旧备份
    }

    f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
    if err != nil {
        log.Printf("warning: cannot open log file: %v", err)
        return
    }
    log.SetOutput(io.MultiWriter(os.Stdout, f))
}
```

### 模块 B: Swift 侧日志增强（speaklow-app/Sources/）

#### B1: viLog 日志轮转

**改动文件**: `AppState.swift` 的 `viLog()` 函数

启动时检查 `SpeakLow.log` 大小，>5MB 则轮转为 `.1.log`。
新增 `rotateLogIfNeeded()` 函数，在 `AppState.init()` 中调用一次。

```swift
private func rotateLogIfNeeded() {
    let logPath = NSHomeDirectory() + "/Library/Logs/SpeakLow.log"
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
          let size = attrs[.size] as? Int, size > 5 * 1024 * 1024 else { return }
    let backupPath = logPath + ".1.log"
    try? FileManager.default.removeItem(atPath: backupPath)
    try? FileManager.default.moveItem(atPath: logPath, toPath: backupPath)
}
```

#### B2: 流式识别关键节点日志

**改动文件**: `StreamingTranscriptionService.swift`

在 WebSocket 事件处理中补充关键日志:
- 连接成功/失败: `viLog("WS connected to \(url)")` / `viLog("WS connect failed: \(error)")`
- 收到 partial 文本（降频，每 5 条记 1 条）: `viLog("WS partial #\(count): '\(text.prefix(40))'")`
- 收到 final 句子: `viLog("WS final: '\(text.prefix(60))'  (\(text.count) chars)")`
- 连接关闭: `viLog("WS closed: code=\(code), reason=\(reason)")`
- stall 检测触发: 已有相关日志，确认覆盖即可

**改动文件**: `AppState.swift`

- ASR mode 切换时记录 bridge 操作: `viLog("ASR mode: \(old) → \(new), bridge action: start/stop")`

### 模块 C: 诊断包导出

**改动文件**: `MenuBarView.swift`, 新增 `DiagnosticExporter.swift`

在菜单栏添加"导出诊断日志..."菜单项，点击后:

1. 收集以下信息打包为 zip:
   - `~/Library/Logs/SpeakLow.log`（Swift app 日志）
   - `~/Library/Logs/SpeakLow-bridge.log`（Go bridge 日志）
   - 系统信息（macOS 版本、CPU 架构、app 版本）
   - 当前配置（ASR mode、hotkey、LLM refine 开关，**不含 API key**）
   - 最近 3 个录音文件（从 `~/Library/Caches/SpeakLow/recordings/`）

2. 弹出 NSSavePanel 让用户选择保存位置
3. 默认文件名: `SpeakLow-diag-yyyyMMdd-HHmmss.zip`

```swift
class DiagnosticExporter {
    static func export() async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("speaklow-diag-\(timestamp())")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // 1. 复制日志文件
        copyIfExists("~/Library/Logs/SpeakLow.log", to: tempDir)
        copyIfExists("~/Library/Logs/SpeakLow-bridge.log", to: tempDir)

        // 2. 写入系统信息
        let sysInfo = collectSystemInfo()  // macOS版本、架构、app版本
        try sysInfo.write(to: tempDir.appendingPathComponent("system-info.txt"), ...)

        // 3. 写入配置（脱敏）
        let config = collectConfig()  // ASR mode, hotkey, refine enabled（不含 API key）
        try config.write(to: tempDir.appendingPathComponent("config.txt"), ...)

        // 4. 复制最近 3 个录音
        copyRecentRecordings(limit: 3, to: tempDir)

        // 5. 打包为 zip
        return try createZip(from: tempDir)
    }
}
```

菜单项位置: 在"Quit"之前，"Settings"之后。

## 文件改动清单

| 文件 | 改动类型 | 模块 |
|------|---------|------|
| `asr-bridge/main.go` | 修改 | A - 添加 initFileLog() |
| `speaklow-app/Sources/AppState.swift` | 修改 | B1 - viLog 轮转 + B2 mode 切换日志 |
| `speaklow-app/Sources/StreamingTranscriptionService.swift` | 修改 | B2 - WS 关键节点日志 |
| `speaklow-app/Sources/DiagnosticExporter.swift` | 新增 | C - 诊断包导出逻辑 |
| `speaklow-app/Sources/MenuBarView.swift` | 修改 | C - 添加菜单项 |

## Worktree 并行策略

| Worktree | 分支 | 内容 | 依赖 |
|----------|------|------|------|
| A | fix/bridge-file-log | Go bridge 文件日志 + 轮转 | 无 |
| B | fix/swift-log-enhance | viLog 轮转 + 流式日志 + mode 切换日志 | 无 |
| C | feat/diagnostic-export | DiagnosticExporter + 菜单项 | 无 |

三个 worktree 完全独立，可并行开发，最后合并到 feat/batch-asr-strategy。

## 测试计划

- Go bridge: `go build` 编译通过 + `go test ./...` 通过
- Swift: `make all` 编译通过
- 合并后: `make all` + 手动验证菜单项可用、日志文件生成
