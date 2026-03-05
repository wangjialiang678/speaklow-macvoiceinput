import AppKit
import ApplicationServices
import os.log

private let insertLog = OSLog(subsystem: "com.speaklow.app", category: "TextInserter")

class TextInserter {
    enum InsertResult: CustomStringConvertible {
        case insertedViaAX       // AX API direct insert succeeded
        case pastedViaClipboard  // Fallback to clipboard + Cmd+V
        case copiedToClipboard   // Only copied to clipboard (paste failed)

        var description: String {
            switch self {
            case .insertedViaAX: return "insertedViaAX"
            case .pastedViaClipboard: return "pastedViaClipboard"
            case .copiedToClipboard: return "copiedToClipboard"
            }
        }
    }

    private enum AXInsertResult {
        case success
        case axDisabled      // AX API returned -25211: permission not granted
        case failed          // AX available but insert failed (e.g., Electron apps)
    }

    static func insert(_ text: String) -> InsertResult {
        viLog("TextInserter.insert() called, text='\(text.prefix(50))' length=\(text.count)")

        // Log which app is frontmost
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            viLog("TextInserter: frontmost app=\(frontApp.localizedName ?? "?") bundle=\(frontApp.bundleIdentifier ?? "?")")
        }

        // 1. Try AX API insert
        let axResult = tryInsertViaAX(text)
        switch axResult {
        case .success:
            viLog("TextInserter: AX insert succeeded")
            return .insertedViaAX
        case .axDisabled:
            // AX API is disabled — CGEvent paste won't work either (same permission).
            // Just copy to clipboard so the user can paste manually.
            viLog("TextInserter: AX API disabled, copying to clipboard only")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return .copiedToClipboard
        case .failed:
            viLog("TextInserter: AX insert failed, falling back to clipboard+paste")
        }

        // 2. Fall back to clipboard + Cmd+V
        return pasteViaClipboard(text)
    }

    private static func pasteViaClipboard(_ text: String) -> InsertResult {
        let previousContents = saveClipboard()

        // 记录粘贴前的文本长度，用于后续验证
        let beforeLen = readFocusedElementValueLength()

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        viLog("TextInserter: text set to clipboard, sending Cmd+V")

        // Small delay to let clipboard settle
        Thread.sleep(forTimeInterval: 0.05)

        let pasted = trySendPasteCommand()
        viLog("TextInserter: Cmd+V sent, result=\(pasted)")

        if pasted {
            // 等待目标 app 处理粘贴事件并更新 AX tree。
            // Electron app（VS Code 等）AX 值更新较慢，250ms 足够覆盖。
            Thread.sleep(forTimeInterval: 0.25)

            let afterLen = readFocusedElementValueLength()
            viLog("TextInserter: paste verify before=\(beforeLen) after=\(afterLen) (expected change of \(text.count))")

            if beforeLen >= 0 && afterLen >= 0 && afterLen == beforeLen {
                // 文本框值没变化，Cmd+V 可能被 macOS 静默丢弃（权限中间状态）
                viLog("TextInserter: paste verification FAILED — value unchanged, CGEvent likely dropped")
                // 不恢复剪贴板，文本留在剪贴板供用户手动粘贴
                return .copiedToClipboard
            }

            viLog("TextInserter: paste verified OK")

            // 延迟恢复剪贴板，给目标 app 时间处理粘贴
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                restoreClipboard(previousContents)
            }
            return .pastedViaClipboard
        }

        viLog("TextInserter: paste command failed, text remains in clipboard")
        return .copiedToClipboard
    }

    /// 读取当前焦点元素的文本值长度，用于粘贴前后对比验证。
    /// 返回 -1 表示无法读取（无焦点元素或不支持 kAXValueAttribute）。
    private static func readFocusedElementValueLength() -> Int {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let element = focusedRef,
              CFGetTypeID(element) == AXUIElementGetTypeID() else {
            return -1
        }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element as! AXUIElement, kAXValueAttribute as CFString, &valueRef
        ) == .success, let value = valueRef as? String else {
            return -1
        }
        return value.count
    }

    // MARK: - AX API

    private static func tryInsertViaAX(_ text: String) -> AXInsertResult {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedElementRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        )

        guard result == .success,
              let rawElement = focusedElementRef,
              CFGetTypeID(rawElement) == AXUIElementGetTypeID() else {
            viLog("TextInserter AX: no focused element (result=\(result.rawValue))")
            // -25211 = kAXErrorAPIDisabled: Accessibility permission not granted
            if result.rawValue == -25211 {
                return .axDisabled
            }
            return .failed
        }

        let focusedElement = rawElement as! AXUIElement

        // Log the role and app
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focusedElement, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            viLog("TextInserter AX: focused element role=\(role)")
        }

        // Check if the element supports selected text range
        var rangeRef: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        )

        guard rangeResult == .success else {
            viLog("TextInserter AX: no selected text range (result=\(rangeResult.rawValue))")
            return .failed
        }

        // Read current value before insert for verification
        var beforeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &beforeRef)
        let beforeLen = (beforeRef as? String)?.count ?? -1

        // Set the selected text to our text
        let setResult = AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )

        viLog("TextInserter AX: set selected text result=\(setResult.rawValue)")

        guard setResult == .success else {
            return .failed
        }

        // Verify: read value back after insert
        Thread.sleep(forTimeInterval: 0.05)
        var afterRef: CFTypeRef?
        AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &afterRef)
        let afterLen = (afterRef as? String)?.count ?? -1

        viLog("TextInserter AX: verify before=\(beforeLen) after=\(afterLen) (expected +\(text.count))")

        // If the value didn't change, AX lied to us — fall through to clipboard
        if afterLen >= 0 && beforeLen >= 0 && afterLen == beforeLen {
            viLog("TextInserter AX: value unchanged after set! AX reported success but didn't actually insert. Falling back.")
            return .failed
        }

        return .success
    }

    // MARK: - Clipboard

    private static func saveClipboard() -> [(NSPasteboard.PasteboardType, Data)] {
        var saved: [(NSPasteboard.PasteboardType, Data)] = []
        let pasteboard = NSPasteboard.general
        guard let items = pasteboard.pasteboardItems else { return saved }
        for item in items {
            for type in item.types {
                if let data = item.data(forType: type) {
                    saved.append((type, data))
                }
            }
        }
        return saved
    }

    private static func restoreClipboard(_ contents: [(NSPasteboard.PasteboardType, Data)]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !contents.isEmpty {
            let item = NSPasteboardItem()
            for (type, data) in contents {
                item.setData(data, forType: type)
            }
            pasteboard.writeObjects([item])
        }
    }

    // MARK: - Paste via CGEvent

    private static func trySendPasteCommand() -> Bool {
        // CGEvent posting requires Accessibility permission.
        // Without it, events are created but silently dropped by macOS.
        guard AXIsProcessTrusted() else {
            viLog("TextInserter: CGEvent paste skipped — no Accessibility permission")
            return false
        }

        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)

        return keyDown != nil && keyUp != nil
    }
}
