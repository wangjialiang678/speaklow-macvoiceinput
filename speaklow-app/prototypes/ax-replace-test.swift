#!/usr/bin/swift
//
// ax-replace-test.swift
// 验证 AX API "原地替换文字" 在不同 macOS 应用中的可行性
//
// 用法: swift prototypes/ax-replace-test.swift
// 运行后在倒计时内切到目标应用的输入框
//

import Cocoa
import ApplicationServices
import Foundation

// MARK: - Logger

let logDir = FileManager.default.temporaryDirectory.appendingPathComponent("ax-replace-test")
let logFile: URL = {
    try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    return logDir.appendingPathComponent("run-\(ts).log")
}()
var logHandle: FileHandle? = {
    FileManager.default.createFile(atPath: logFile.path, contents: nil)
    return try? FileHandle(forWritingTo: logFile)
}()

func log(_ msg: String) {
    let ts = String(format: "%.3f", Date().timeIntervalSince1970)
    let line = "[\(ts)] \(msg)\n"
    print(msg) // 同时输出到终端
    if let data = line.data(using: .utf8) {
        logHandle?.write(data)
    }
}

// MARK: - 模拟数据

// 场景1: 正常递增（每次都是前一次的延伸）
let partialResults = [
    "你",
    "你好",
    "你好世界",
    "你好世界，",
    "你好世界，今天",
    "你好世界，今天天气",
    "你好世界，今天天气真好。",
]

// 场景2: 模拟 ASR 修正（中间某步修正了前面的字）
let partialResultsWithCorrection = [
    "今天",
    "今天天",
    "今天天时",        // ASR 暂时识别为"时"
    "今天天气",        // ASR 修正: "时" → "气" (回退1字)
    "今天天气真好",
    "今天天气真好。",
]

// 场景3: 模拟多句连续输出（每个元素是一个 sentence_end=true 的完整句子）
let sentenceResults = [
    "你好世界，",
    "今天天气真好。",
    "我们一起出去走走吧！",
]

let stepDelay: UInt32 = 300_000 // 300ms, usleep 单位是微秒

// MARK: - AX Helpers

func getFocusedElement() -> AXUIElement? {
    let systemWide = AXUIElementCreateSystemWide()
    var ref: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &ref)

    log("[diag] AXIsProcessTrusted = \(AXIsProcessTrusted())")
    log("[diag] kAXFocusedUIElement result = \(result.rawValue)")
    if let app = NSWorkspace.shared.frontmostApplication {
        log("[diag] frontmostApp = \(app.localizedName ?? "?") pid=\(app.processIdentifier) (\(app.bundleIdentifier ?? "?"))")
    }

    // 如果直接获取失败，尝试通过前台应用的 PID 获取
    if result != .success {
        log("[diag] systemWide 方式失败(code=\(result.rawValue))，尝试 PID 方式...")
        if let app = NSWorkspace.shared.frontmostApplication {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var focusedRef: CFTypeRef?
            let pidResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
            log("[diag] PID 方式 result = \(pidResult.rawValue)")
            if pidResult == .success, let el = focusedRef, CFGetTypeID(el) == AXUIElementGetTypeID() {
                log("[diag] PID 方式成功")
                return (el as! AXUIElement)
            }
        }
        log("[diag] 两种方式均失败")
        return nil
    }

    guard let element = ref else {
        log("[diag] ref 为 nil")
        return nil
    }
    guard CFGetTypeID(element) == AXUIElementGetTypeID() else {
        log("[diag] ref 类型不匹配: \(CFGetTypeID(element)) != \(AXUIElementGetTypeID())")
        return nil
    }
    return (element as! AXUIElement)
}

func getElementRole(_ element: AXUIElement) -> String {
    var ref: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref)
    return (ref as? String) ?? "unknown"
}

func getElementValue(_ element: AXUIElement) -> String? {
    var ref: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref)
    guard result == .success else { return nil }
    return ref as? String
}

func getSelectedTextRange(_ element: AXUIElement) -> CFRange? {
    var ref: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref)
    guard result == .success, let value = ref else { return nil }
    var range = CFRange(location: 0, length: 0)
    if AXValueGetValue(value as! AXValue, .cfRange, &range) {
        return range
    }
    return nil
}

func setSelectedTextRange(_ element: AXUIElement, location: Int, length: Int) -> Bool {
    var range = CFRange(location: location, length: length)
    guard let value = AXValueCreate(.cfRange, &range) else { return false }
    let result = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
    log("[ax] setSelectedTextRange(loc=\(location), len=\(length)) → \(result.rawValue)")
    return result == .success
}

func setSelectedText(_ element: AXUIElement, text: String) -> Bool {
    let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
    log("[ax] setSelectedText(\"\(text)\") → \(result.rawValue)")
    return result == .success
}

func getFrontmostApp() -> (name: String, bundleId: String) {
    if let app = NSWorkspace.shared.frontmostApplication {
        return (app.localizedName ?? "unknown", app.bundleIdentifier ?? "unknown")
    }
    return ("unknown", "unknown")
}

// MARK: - 辅助：计算公共前缀长度

func commonPrefixLength(_ a: String, _ b: String) -> Int {
    var count = 0
    var ai = a.startIndex, bi = b.startIndex
    while ai < a.endIndex && bi < b.endIndex && a[ai] == b[bi] {
        count += 1
        ai = a.index(after: ai)
        bi = b.index(after: bi)
    }
    return count
}

// MARK: - 方法 A: AX 全量替换（旧方案，作为对比基线）

func testMethodA(element: AXUIElement) -> Bool {
    log("\n[测试 1: AX 全量替换（基线对比）]")

    guard let initialRange = getSelectedTextRange(element) else {
        log("  FAIL 无法读取光标位置 (kAXSelectedTextRangeAttribute)")
        return false
    }
    let insertStart = initialRange.location
    log("  插入起始位置: \(insertStart)")

    var previousLength = 0

    for (i, partial) in partialResults.enumerated() {
        let isFirst = (i == 0)
        let isFinal = (i == partialResults.count - 1)

        if !isFirst {
            let selectOk = setSelectedTextRange(element, location: insertStart, length: previousLength)
            if !selectOk {
                log("  FAIL \"\(partial)\" → 选区设置失败 (location=\(insertStart), length=\(previousLength))")
                return false
            }
        }

        let writeOk = setSelectedText(element, text: partial)
        if !writeOk {
            log("  FAIL \"\(partial)\" → 写入失败 (kAXSelectedTextAttribute)")
            return false
        }

        usleep(50_000)
        if let value = getElementValue(element) {
            let partialLen = partial.count
            let safeStart = min(insertStart, value.count)
            let safeEnd = min(safeStart + partialLen, value.count)
            let start = value.index(value.startIndex, offsetBy: safeStart)
            let end = value.index(value.startIndex, offsetBy: safeEnd)
            let actual = String(value[start..<end])

            if actual == partial {
                let label = isFinal ? "最终结果" : "替换成功"
                log("  OK \"\(partial)\" → \(label)")
            } else {
                log("  WARN \"\(partial)\" → 验证不一致: actual=\"\(actual)\"")
            }
        } else {
            log("  OK? \"\(partial)\" → 写入成功(无法读回验证)")
        }

        previousLength = partial.count
        if !isFinal { usleep(stepDelay) }
    }

    return true
}

// MARK: - 方法 C: 增量追加（新方案）

func testMethodC(element: AXUIElement) -> Bool {
    log("\n[测试 3: 增量追加（仅追加差异部分）]")

    guard let initialRange = getSelectedTextRange(element) else {
        log("  FAIL 无法读取光标位置")
        return false
    }
    let insertStart = initialRange.location
    log("  插入起始位置: \(insertStart)")

    var previousText = ""

    for (i, partial) in partialResults.enumerated() {
        let isFinal = (i == partialResults.count - 1)
        let commonLen = commonPrefixLength(previousText, partial)

        if commonLen == previousText.count {
            // 新文字是旧文字的延伸 → 只追加差异部分
            let appendText = String(partial.dropFirst(commonLen))
            log("[incremental] 公共前缀=\(commonLen) 追加=\"\(appendText)\"")

            // 光标应该已经在上次插入的末尾，直接写入
            let writeOk = setSelectedText(element, text: appendText)
            if !writeOk {
                log("  FAIL \"\(partial)\" → 追加写入失败")
                return false
            }
        } else {
            // ASR 修正了前面的字 → 需要回退替换
            let rollbackLen = previousText.count - commonLen
            let newSuffix = String(partial.dropFirst(commonLen))
            log("[incremental] ASR修正! 公共前缀=\(commonLen) 回退\(rollbackLen)字 写入=\"\(newSuffix)\"")

            // 选中从公共前缀结束位置到上次末尾的范围
            let selectOk = setSelectedTextRange(element, location: insertStart + commonLen, length: rollbackLen)
            if !selectOk {
                log("  FAIL \"\(partial)\" → 回退选区失败")
                return false
            }
            let writeOk = setSelectedText(element, text: newSuffix)
            if !writeOk {
                log("  FAIL \"\(partial)\" → 回退写入失败")
                return false
            }
        }

        usleep(50_000)

        // 验证
        if let value = getElementValue(element) {
            let safeStart = min(insertStart, value.count)
            let safeEnd = min(safeStart + partial.count, value.count)
            let start = value.index(value.startIndex, offsetBy: safeStart)
            let end = value.index(value.startIndex, offsetBy: safeEnd)
            let actual = String(value[start..<end])

            if actual == partial {
                let label = isFinal ? "最终结果" : (commonLen == previousText.count ? "追加成功" : "修正成功")
                log("  OK \"\(partial)\" → \(label)")
            } else {
                log("  WARN \"\(partial)\" → 验证不一致: actual=\"\(actual)\"")
            }
        } else {
            log("  OK? \"\(partial)\" → 已执行(无法读回)")
        }

        previousText = partial
        if !isFinal { usleep(stepDelay) }
    }

    return true
}

// MARK: - 方法 B: 退格键删除 + AX 重新插入

func sendBackspace(count: Int) {
    let source = CGEventSource(stateID: .hidSystemState)
    for _ in 0..<count {
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true) {
            keyDown.post(tap: .cgSessionEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) {
            keyUp.post(tap: .cgSessionEventTap)
        }
        usleep(10_000)
    }
}

func testMethodB(element: AXUIElement) -> Bool {
    log("\n[测试 2: 退格键删除 + AX 重新插入]")

    var previousLength = 0

    for (i, partial) in partialResults.enumerated() {
        let isFirst = (i == 0)
        let isFinal = (i == partialResults.count - 1)

        if !isFirst && previousLength > 0 {
            log("[method-b] sendBackspace(\(previousLength))")
            sendBackspace(count: previousLength)
            usleep(50_000)
        }

        let writeOk = setSelectedText(element, text: partial)
        if !writeOk {
            log("  WARN AX 写入失败，尝试剪贴板粘贴...")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(partial, forType: .string)
            usleep(30_000)
            let source = CGEventSource(stateID: .hidSystemState)
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) {
                keyDown.flags = .maskCommand
                keyDown.post(tap: .cgSessionEventTap)
            }
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) {
                keyUp.flags = .maskCommand
                keyUp.post(tap: .cgSessionEventTap)
            }
            usleep(50_000)
        }

        usleep(50_000)

        if let value = getElementValue(element) {
            if value.contains(partial) {
                let label = isFinal ? "最终结果" : "替换成功"
                log("  OK \"\(partial)\" → \(label)")
            } else {
                log("  WARN \"\(partial)\" → 验证不一致: value_tail=\"\(value.suffix(30))\"")
            }
        } else {
            log("  OK? \"\(partial)\" → 已执行(无法读回验证)")
        }

        previousLength = partial.count
        if !isFinal { usleep(stepDelay) }
    }

    return true
}

// MARK: - 方法 C 的通用版本（接受自定义数据）

func testMethodCWithData(element: AXUIElement, data: [String]) -> Bool {
    log("\n[测试 3b: 增量追加（含ASR修正）]")

    guard let initialRange = getSelectedTextRange(element) else {
        log("  FAIL 无法读取光标位置")
        return false
    }
    let insertStart = initialRange.location
    log("  插入起始位置: \(insertStart)")

    var previousText = ""

    for (i, partial) in data.enumerated() {
        let isFinal = (i == data.count - 1)
        let commonLen = commonPrefixLength(previousText, partial)

        if commonLen == previousText.count {
            let appendText = String(partial.dropFirst(commonLen))
            log("[incremental] 公共前缀=\(commonLen) 追加=\"\(appendText)\"")
            let writeOk = setSelectedText(element, text: appendText)
            if !writeOk {
                log("  FAIL \"\(partial)\" → 追加写入失败")
                return false
            }
        } else {
            let rollbackLen = previousText.count - commonLen
            let newSuffix = String(partial.dropFirst(commonLen))
            log("[incremental] ASR修正! 公共前缀=\(commonLen) 回退\(rollbackLen)字 写入=\"\(newSuffix)\"")
            let selectOk = setSelectedTextRange(element, location: insertStart + commonLen, length: rollbackLen)
            if !selectOk {
                log("  FAIL \"\(partial)\" → 回退选区失败")
                return false
            }
            let writeOk = setSelectedText(element, text: newSuffix)
            if !writeOk {
                log("  FAIL \"\(partial)\" → 回退写入失败")
                return false
            }
        }

        usleep(50_000)

        if let value = getElementValue(element) {
            let safeStart = min(insertStart, value.count)
            let safeEnd = min(safeStart + partial.count, value.count)
            let start = value.index(value.startIndex, offsetBy: safeStart)
            let end = value.index(value.startIndex, offsetBy: safeEnd)
            let actual = String(value[start..<end])

            if actual == partial {
                let label = isFinal ? "最终结果" : (commonLen == previousText.count ? "追加成功" : "修正成功")
                log("  OK \"\(partial)\" → \(label)")
            } else {
                log("  WARN \"\(partial)\" → 验证不一致: actual=\"\(actual)\"")
            }
        } else {
            log("  OK? \"\(partial)\" → 已执行(无法读回)")
        }

        previousText = partial
        if !isFinal { usleep(stepDelay) }
    }

    return true
}

// MARK: - 方法 D: 逐句剪贴板粘贴（Electron 兼容方案）

func sendPaste() {
    let source = CGEventSource(stateID: .hidSystemState)
    if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) {
        keyDown.flags = .maskCommand
        keyDown.post(tap: .cgSessionEventTap)
    }
    if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) {
        keyUp.flags = .maskCommand
        keyUp.post(tap: .cgSessionEventTap)
    }
}

func testMethodD() -> Bool {
    log("\n[测试 4: 逐句剪贴板粘贴（模拟 sentence_end）]")

    // 保存用户剪贴板
    let savedItems: [(NSPasteboard.PasteboardType, Data)] = {
        var saved: [(NSPasteboard.PasteboardType, Data)] = []
        for item in NSPasteboard.general.pasteboardItems ?? [] {
            for type in item.types {
                if let data = item.data(forType: type) { saved.append((type, data)) }
            }
        }
        return saved
    }()

    for (i, sentence) in sentenceResults.enumerated() {
        let isFinal = (i == sentenceResults.count - 1)

        // 模拟等待 ASR sentence_end（真实场景中用户说完一句约 1-3 秒）
        log("  [sentence_end] 收到第 \(i+1) 句: \"\(sentence)\"")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sentence, forType: .string)
        usleep(30_000)
        sendPaste()
        usleep(100_000) // 等粘贴完成

        log("  OK \"\(sentence)\" → \(isFinal ? "最终句" : "已粘贴")")

        if !isFinal {
            // 模拟句间间隔（真实场景约 1-2 秒）
            usleep(800_000)
        }
    }

    // 恢复剪贴板
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        NSPasteboard.general.clearContents()
        for (type, data) in savedItems {
            NSPasteboard.general.setData(data, forType: type)
        }
    }

    log("  剪贴板已恢复")
    return true
}

// MARK: - 清理辅助

func clearInsertedText(element: AXUIElement, startPos: Int, length: Int) {
    if setSelectedTextRange(element, location: startPos, length: length) {
        _ = setSelectedText(element, text: "")
    }
}

// MARK: - Main

func main() {
    log("=== AX 原地更新文字 可行性测试 ===")
    log("日志文件: \(logFile.path)")

    let trusted = AXIsProcessTrusted()
    log("[diag] AXIsProcessTrusted = \(trusted)")
    if !trusted {
        log("FATAL 需要辅助功能权限！")
        log("  系统设置 → 隐私与安全 → 辅助功能 → 添加 Terminal / iTerm / swift")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        exit(1)
    }

    log("请在 5 秒内点击目标应用的输入框...\n")
    for i in (1...5).reversed() {
        log("  \(i)...")
        sleep(1)
    }
    log("")

    let app = getFrontmostApp()
    log("[diag] 倒计时结束，当前前台: \(app.name) (\(app.bundleId))")

    guard let element = getFocusedElement() else {
        log("FATAL 无法获取焦点元素。请确保光标在一个文本输入框内。")
        log("日志已保存: \(logFile.path)")
        logHandle?.closeFile()
        exit(1)
    }

    let role = getElementRole(element)
    log("目标应用: \(app.name) (\(app.bundleId))")
    log("元素类型: \(role)")

    let initialRange = getSelectedTextRange(element)
    let insertStart = initialRange?.location ?? 0
    log("[diag] initialRange = location:\(initialRange?.location ?? -1) length:\(initialRange?.length ?? -1)")

    // --- 测试方法 C: 增量追加（正常递增） ---
    let resultC = testMethodC(element: element)

    let finalLen = partialResults.last!.count
    clearInsertedText(element: element, startPos: insertStart, length: finalLen)
    usleep(300_000)

    // --- 测试方法 C: 增量追加（含 ASR 修正） ---
    log("\n--- 下面测试含 ASR 修正的场景 ---")
    // 暂存原始数据，替换为修正场景数据
    let resultC2 = testMethodCWithData(element: element, data: partialResultsWithCorrection)

    let finalLen2 = partialResultsWithCorrection.last!.count
    if let range = getSelectedTextRange(element) {
        clearInsertedText(element: element, startPos: max(0, range.location - finalLen2), length: finalLen2)
    }
    usleep(300_000)

    // --- 测试方法 A: 全量替换（基线对比） ---
    let resultA = testMethodA(element: element)

    let finalLenA = partialResults.last!.count
    clearInsertedText(element: element, startPos: insertStart, length: finalLenA)
    usleep(300_000)

    // --- 测试方法 D: 逐句剪贴板粘贴 ---
    let resultD = testMethodD()
    usleep(300_000)

    // --- 测试方法 B: 退格+重写 ---
    let resultB = testMethodB(element: element)

    if let range = getSelectedTextRange(element) {
        let currentLen = partialResults.last!.count
        clearInsertedText(element: element, startPos: max(0, range.location - currentLen), length: currentLen)
    }

    // --- 汇总 ---
    log("\n" + String(repeating: "=", count: 50))
    log("测试结果汇总")
    log(String(repeating: "=", count: 50))
    log("目标应用:       \(app.name) (\(app.bundleId))")
    log("元素类型:       \(role)")
    log("方法 C (增量追加):     \(resultC ? "OK" : "FAIL")  ← 原生app推荐")
    log("方法 C (含ASR修正):    \(resultC2 ? "OK" : "FAIL")")
    log("方法 D (逐句粘贴):     \(resultD ? "OK" : "FAIL")  ← 全平台兼容")
    log("方法 A (全量替换):     \(resultA ? "OK" : "FAIL")  ← 基线")
    log("方法 B (退格+重写):    \(resultB ? "OK" : "FAIL")")

    if resultC {
        log("\n建议: 此应用可使用增量追加（最优，无闪烁）+ 逐句粘贴兜底")
    } else if resultD {
        log("\n建议: 此应用 AX 不可写，使用逐句剪贴板粘贴（说一句出一句）")
    } else {
        log("\n建议: 此应用可能仅支持录完后一次性插入")
    }

    log("\n日志已保存: \(logFile.path)")
    logHandle?.closeFile()
}

main()
