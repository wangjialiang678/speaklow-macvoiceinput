# 代码审核报告：Batch ASR Strategy 架构重构

> 审核日期：2026-03-06
> 审核方式：4 个并行 Reviewer 子代理 + Go 测试基线
> 分支：`feat/batch-asr-strategy`
> 变更量：9 文件，+684 / -67 行

---

## 测试基线

| 测试套件 | 结果 | 说明 |
|---------|------|------|
| Go bridge tests | ✅ 118/118 PASS | 含 37 攻击场景 × 3 配置 + 基础/风格测试 |
| Swift 编译 | ✅ 上次 commit 通过 | 无 Swift 测试框架，依赖 make run |

---

## 汇总：所有发现的问题

### P0 — 必须修复（6 个）

| # | 模块 | 问题 | 审批意见 |
|---|------|------|----------|
| P0-1 | AppState | **Strategy 模式定义但未完全集成** — AppState 仍用 `switch asrMode` 分支，TranscriptionStrategy 协议未被实际调用 | ✅ **同意修复** — 但方向是完成集成而非删除。BatchStrategy 已有完整实现，应替换 AppState 中的 switch 分支。StreamingStrategy 保持过渡实现（FIXME 注释），Phase 2 再完善 |
| P0-2 | AppState | **toggleRecording() 不区分模式** — 总是调用 stopAndTranscribe()，流式模式下会丢失实时预览文本 | ✅ **同意修复** — 改为 `switch asrMode` 调用对应 stop 方法 |
| P0-3 | AppDelegate | **Bridge 启动时序竞态** — AppDelegate 和 asrMode didSet 都管 Bridge 生命周期，可能冲突 | ⚠️ **部分同意** — AppDelegate 中的启动是冷启动必要的（didSet 在 init 时不触发），但应改为幂等调用。保留 AppDelegate 启动逻辑，但加 `guard !bridge.isRunning` |
| P0-4 | ASRBridgeManager | **terminationHandler 竞态条件** — process 置 nil 和 stop() 并发不安全 | ✅ **同意修复** — 用 DispatchQueue.main.async 包裹 terminationHandler 内部逻辑 |
| P0-5 | ASRBridgeManager | **Auto-restart 无限循环风险** — start() 失败会递归触发 terminationHandler | ✅ **同意修复** — 添加 maxConsecutiveRestarts = 3 限制，启动成功后重置计数 |
| P0-6 | DashScopeClient | **convertTo16kMono 临时文件泄漏** — 异常分支未清理 convertedURL | ✅ **同意修复** — 用 defer 模式清理 |

### P1 — 应当修复（7 个）

| # | 模块 | 问题 | 审批意见 |
|---|------|------|----------|
| P1-1 | AppState | **stopAndTranscribe() 与 stopAndTranscribeBatch() 重复 ~85%** | ✅ **同意** — 统一为 stopAndTranscribeBatch()，删除旧方法 |
| P1-2 | TranscriptionStrategy | **BatchStrategy.finish() 的 recorder.stopRecording() 线程安全** | ✅ **同意** — 在 finish() 中用 `await MainActor.run` 调用 stopRecording |
| P1-3 | TranscriptionStrategy | **isCorpusLeak 是外部全局函数依赖** | ⚠️ **降级为 P2** — 当前全局函数能工作，Strategy 内移入是代码质量改进而非功能缺陷。等 Phase 2 统一处理 |
| P1-4 | ASRBridgeManager | **healthTimer 回调与 stop() 竞态** | ✅ **同意** — 在 timer 回调内加 `guard self.healthTimer != nil` |
| P1-5 | ASRBridgeManager | **start() 找不到二进制文件时静默返回而非抛错** | ✅ **同意** — 改为 throw NSError |
| P1-6 | DashScopeClient | **transcribe 缺少音频文件存在性校验** | ✅ **同意** — 添加 FileManager.fileExists 检查 |
| P1-7 | DashScopeClient | **Process.waitUntilExit() 无超时** — afconvert 可能无限等待 | ✅ **同意** — 用 DispatchSemaphore + 10s 超时 |

### P2 — 建议改进（不在本次修复范围，记录备忘）

| # | 问题 | 备注 |
|---|------|------|
| P2-1 | URL 强制解包改为 guard let | 低风险，URL 是常量 |
| P2-2 | JSONSerialization 改为 Codable | 未来重构 |
| P2-3 | 长度卫士改为 utf16.count | 实际差异极小 |
| P2-4 | 日志 viLog vs os_log 统一 | 全局清理 |
| P2-5 | 错误消息中英文统一 | UI 整体优化时处理 |
| P2-6 | @unchecked Sendable 添加注释 | 文档改进 |
| P2-7 | hotword TAB vs 空格分隔符兼容 | 当前 hotwords.txt 全用 TAB，暂无问题 |

---

## 修复计划

### Worktree A: AppState + Strategy 集成（P0-1, P0-2, P1-1）
- 完成 Strategy 模式集成：AppState.beginRecording/handleHotkeyUp 通过 strategy 接口调用
- toggleRecording() 区分模式
- 合并 stopAndTranscribe() 到 stopAndTranscribeBatch()

### Worktree B: ASRBridgeManager 鲁棒性（P0-4, P0-5, P1-4, P1-5）
- terminationHandler 线程安全
- 重启次数限制
- healthTimer 竞态修复
- start() 错误传播

### Worktree C: DashScopeClient 防御性编程（P0-6, P1-6, P1-7）
- 临时文件清理 defer
- 音频文件存在性校验
- afconvert 超时保护

### Worktree D: TranscriptionStrategy 线程安全（P1-2, P0-3）
- BatchStrategy.finish() MainActor 隔离
- AppDelegate Bridge 启动幂等化

---

## 审批状态

**审批人**：待用户确认
**审批日期**：2026-03-06

- [ ] 确认 P0 修复方案
- [ ] 确认 P1 修复范围
- [ ] 确认 P2 延迟处理
- [ ] 批准 Worktree 并行修复
