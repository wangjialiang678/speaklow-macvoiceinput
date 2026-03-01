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

    static func insert(_ text: String) -> InsertResult {
        viLog("TextInserter.insert() called, text='\(text.prefix(50))' length=\(text.count)")

        // Log which app is frontmost
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            viLog("TextInserter: frontmost app=\(frontApp.localizedName ?? "?") bundle=\(frontApp.bundleIdentifier ?? "?")")
        }

        // 1. Try AX API insert
        if tryInsertViaAX(text) {
            viLog("TextInserter: AX insert succeeded")
            return .insertedViaAX
        }
        viLog("TextInserter: AX insert failed, falling back to clipboard+paste")

        // 2. Fall back to clipboard + Cmd+V
        return pasteViaClipboard(text)
    }

    private static func pasteViaClipboard(_ text: String) -> InsertResult {
        let previousContents = saveClipboard()

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        viLog("TextInserter: text set to clipboard, sending Cmd+V")

        // Small delay to let clipboard settle
        Thread.sleep(forTimeInterval: 0.05)

        let pasted = trySendPasteCommand()
        viLog("TextInserter: Cmd+V sent, result=\(pasted)")

        // Restore clipboard after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            restoreClipboard(previousContents)
        }

        if pasted {
            return .pastedViaClipboard
        }

        viLog("TextInserter: paste failed, text remains in clipboard")
        return .copiedToClipboard
    }

    // MARK: - AX API

    private static func tryInsertViaAX(_ text: String) -> Bool {
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
            return false
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
            return false
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
            return false
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
            return false
        }

        return true
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

    // MARK: - Streaming Session (clipboard saved once, restored at end)

    private static var streamingClipboard: [(NSPasteboard.PasteboardType, Data)]?

    /// Save clipboard at the start of a streaming session (call once).
    static func beginStreamingSession() {
        streamingClipboard = saveClipboard()
        viLog("TextInserter: clipboard saved for streaming session")
    }

    /// Paste a single sentence during streaming (no per-sentence clipboard save/restore).
    static func insertSentence(_ text: String) -> InsertResult {
        viLog("TextInserter.insertSentence() called, text='\(text.prefix(50))'")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Thread.sleep(forTimeInterval: 0.05)

        let pasted = trySendPasteCommand()
        viLog("TextInserter: sentence Cmd+V sent, result=\(pasted)")

        return pasted ? .pastedViaClipboard : .copiedToClipboard
    }

    /// Restore clipboard after streaming session ends.
    static func endStreamingSession() {
        if let saved = streamingClipboard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                restoreClipboard(saved)
                viLog("TextInserter: clipboard restored after streaming session")
            }
            streamingClipboard = nil
        }
    }

    // MARK: - Paste via CGEvent

    private static func trySendPasteCommand() -> Bool {
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
