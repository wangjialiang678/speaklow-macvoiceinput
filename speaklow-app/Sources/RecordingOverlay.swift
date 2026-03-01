import SwiftUI
import AppKit

// MARK: - State

class RecordingOverlayState: ObservableObject {
    @Published var phase: OverlayPhase = .recording
    @Published var audioLevel: Float = 0.0
}

enum OverlayPhase: Equatable {
    case initializing
    case recording
    case transcribing
    case done
    case error(title: String, suggestion: String)
}

// MARK: - Panel Helpers

private func makeOverlayPanel(width: CGFloat, height: CGFloat) -> NSPanel {
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.level = .screenSaver
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces]
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    return panel
}

/// Wraps a SwiftUI view in an NSView for use as panel content.
private func makeNotchContent<V: View>(
    width: CGFloat,
    height: CGFloat,
    cornerRadius: CGFloat,
    rootView: V
) -> NSView {
    let shaped = rootView
        .frame(width: width, height: height)
        .background(Color.black)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius))

    let hosting = NSHostingView(rootView: shaped)
    hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
    hosting.autoresizingMask = [.width, .height]
    return hosting
}

// MARK: - Manager

class RecordingOverlayManager {
    private var overlayWindow: NSPanel?
    private var transcribingPanel: NSPanel?
    private var overlayState = RecordingOverlayState()

    // Transcription preview panel (floating near bottom-center)
    private var previewPanel: NSPanel?
    private var previewState = TranscriptionPreviewState()

    /// Whether the main screen has a camera housing (notch).
    private var screenHasNotch: Bool {
        guard let screen = NSScreen.main else { return false }
        return screen.safeAreaInsets.top > 0
    }

    /// Width of the camera housing (notch) in points, or 0 if no notch.
    private var notchWidth: CGFloat {
        guard let screen = NSScreen.main, screenHasNotch else { return 0 }
        guard let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else { return 0 }
        return screen.frame.width - leftArea.width - rightArea.width
    }

    func showInitializing() {
        DispatchQueue.main.async {
            self.overlayState.phase = .initializing
            self.overlayState.audioLevel = 0.0
            self._showOverlayPanel()
        }
    }

    func showRecording() {
        DispatchQueue.main.async {
            self.overlayState.phase = .recording
            self.overlayState.audioLevel = 0.0
            self._showOverlayPanel()
        }
    }

    func transitionToRecording() {
        DispatchQueue.main.async { self.overlayState.phase = .recording }
    }

    func updateAudioLevel(_ level: Float) {
        DispatchQueue.main.async { self.overlayState.audioLevel = level }
    }

    func showTranscribing() {
        DispatchQueue.main.async { self._showTranscribing() }
    }

    func slideUpToNotch(completion: @escaping () -> Void) {
        DispatchQueue.main.async { self._slideUpToNotch(completion: completion) }
    }

    func showDone() {
        DispatchQueue.main.async { self._showDone() }
    }

    func dismiss() {
        DispatchQueue.main.async { self._dismiss() }
    }

    func showError(title: String, suggestion: String) {
        DispatchQueue.main.async { self._showError(title: title, suggestion: suggestion) }
    }

    // MARK: - Preview Panel API

    func showPreviewPanel() {
        DispatchQueue.main.async { self._showPreviewPanel() }
    }

    func updatePreviewText(_ text: String) {
        DispatchQueue.main.async {
            // Auto-show panel on first non-empty text
            if self.previewPanel == nil && !text.isEmpty {
                self._showPreviewPanel()
            }
            self.previewState.displayText = text
            self._resizePreviewPanel()
        }
    }

    func dismissPreviewPanel() {
        DispatchQueue.main.async { self._dismissPreviewPanel() }
    }

    /// Height of the notch area (menu bar inset) that the panel extends into.
    private var notchOverlap: CGFloat {
        guard let screen = NSScreen.main else { return 0 }
        return screen.frame.maxY - screen.visibleFrame.maxY
    }

    private func _showOverlayPanel() {
        let hasNotch = screenHasNotch
        let panelWidth: CGFloat = hasNotch ? max(notchWidth, 150) : 150
        let contentHeight: CGFloat = 50
        // On notch screens, extend the panel up into the menu bar to connect with the notch
        let overlap = hasNotch ? notchOverlap : 0
        let panelHeight = contentHeight + overlap

        if let panel = overlayWindow {
            guard let screen = NSScreen.main else { return }
            let x = panelX(screen, width: panelWidth)
            let y: CGFloat
            if hasNotch {
                y = screen.frame.maxY - panelHeight
            } else {
                y = screen.frame.maxY - panelHeight
            }
            panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }

        let panel = makeOverlayPanel(width: panelWidth, height: panelHeight)
        panel.hasShadow = false

        let view = RecordingOverlayView(state: overlayState)
        panel.contentView = makeNotchContent(
            width: panelWidth,
            height: panelHeight,
            cornerRadius: hasNotch ? 18 : 12,
            rootView: view.padding(.top, overlap)
        )

        if let screen = NSScreen.main {
            let x = panelX(screen, width: panelWidth)
            let hiddenY = screen.frame.maxY
            let visibleY = screen.frame.maxY - panelHeight

            panel.setFrame(NSRect(x: x, y: hiddenY, width: panelWidth, height: panelHeight), display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()

            // Spring-like drop: overshoots slightly then settles
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
                panel.animator().setFrame(NSRect(x: x, y: visibleY, width: panelWidth, height: panelHeight), display: true)
            }
        }

        self.overlayWindow = panel
    }

    private func _slideUpToNotch(completion: @escaping () -> Void) {
        guard let panel = overlayWindow, let screen = NSScreen.main else {
            completion()
            return
        }

        let hiddenY = screen.frame.maxY
        let frame = panel.frame

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.09
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1.0, 1.0)
            panel.animator().setFrame(NSRect(x: frame.origin.x, y: hiddenY, width: frame.width, height: frame.height), display: true)
        }, completionHandler: {
            panel.orderOut(nil)
            self.overlayWindow = nil
            completion()
        })
    }

    private func _showTranscribing() {
        overlayState.phase = .transcribing

        if let panel = overlayWindow {
            panel.orderOut(nil)
            overlayWindow = nil
        }

        if transcribingPanel != nil { return }

        let hasNotch = screenHasNotch
        let contentHeight: CGFloat = 22
        let overlap = hasNotch ? notchOverlap : 0
        let panelWidth: CGFloat = 44
        let panelHeight = contentHeight + overlap

        let panel = makeOverlayPanel(width: panelWidth, height: panelHeight)
        panel.hasShadow = false

        let view = TranscribingIndicatorView()
        panel.contentView = makeNotchContent(
            width: panelWidth,
            height: panelHeight,
            cornerRadius: hasNotch ? 14 : 11,
            rootView: view.padding(.top, overlap)
        )

        if let screen = NSScreen.main {
            let x = panelX(screen, width: panelWidth)
            let y = screen.frame.maxY - panelHeight
            panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }

        self.transcribingPanel = panel
    }

    private func _showDone() {
        overlayState.phase = .done

        if let panel = transcribingPanel {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                self.transcribingPanel = nil
            })
        }
    }

    private var errorPanel: NSPanel?

    private func _showError(title: String, suggestion: String) {
        _dismiss()

        let hasNotch = screenHasNotch
        let panelWidth: CGFloat = 240
        let contentHeight: CGFloat = 52
        let overlap = hasNotch ? notchOverlap : 0
        let panelHeight = contentHeight + overlap

        let panel = makeOverlayPanel(width: panelWidth, height: panelHeight)
        panel.hasShadow = false

        let view = ErrorOverlayView(title: title, suggestion: suggestion)
        panel.contentView = makeNotchContent(
            width: panelWidth,
            height: panelHeight,
            cornerRadius: hasNotch ? 18 : 12,
            rootView: view.padding(.top, overlap)
        )

        if let screen = NSScreen.main {
            let x = panelX(screen, width: panelWidth)
            let hiddenY = screen.frame.maxY
            let visibleY = screen.frame.maxY - panelHeight

            panel.setFrame(NSRect(x: x, y: hiddenY, width: panelWidth, height: panelHeight), display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
                panel.animator().setFrame(NSRect(x: x, y: visibleY, width: panelWidth, height: panelHeight), display: true)
            }
        }

        self.errorPanel = panel

        // Auto-dismiss after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, let panel = self.errorPanel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                self.errorPanel = nil
            })
        }
    }

    private func _dismiss() {
        if let panel = overlayWindow {
            panel.orderOut(nil)
            overlayWindow = nil
        }
        if let panel = transcribingPanel {
            panel.orderOut(nil)
            transcribingPanel = nil
        }
        if let panel = errorPanel {
            panel.orderOut(nil)
            errorPanel = nil
        }
        _dismissPreviewPanel()
    }

    private func panelX(_ screen: NSScreen, width: CGFloat) -> CGFloat {
        screen.frame.midX - width / 2
    }

    // MARK: - Preview Panel Private

    private let previewPanelWidth: CGFloat = 520
    private let previewFont = NSFont.systemFont(ofSize: 14)
    private let previewLineSpacing: CGFloat = 4
    private let previewHPad: CGFloat = 28  // 14 × 2
    private let previewVPad: CGFloat = 20  // 10 × 2
    private let previewMaxLines: CGFloat = 10

    private var previewSingleLineHeight: CGFloat {
        let font = previewFont
        return ceil(font.ascender - font.descender + font.leading + previewLineSpacing)
    }

    private func _showPreviewPanel() {
        guard previewPanel == nil else { return }

        previewState.displayText = ""
        let h = previewSingleLineHeight + previewVPad

        let panel = makeOverlayPanel(width: previewPanelWidth, height: h)

        let view = TranscriptionPreviewView(state: previewState)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: previewPanelWidth, height: h)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        if let screen = NSScreen.main {
            let x = screen.frame.midX - previewPanelWidth / 2
            let bottomY = screen.visibleFrame.minY + screen.visibleFrame.height * 0.15
            panel.setFrame(NSRect(x: x, y: bottomY, width: previewPanelWidth, height: h), display: true)
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }

        self.previewPanel = panel
    }

    private func _resizePreviewPanel() {
        guard let panel = previewPanel, let screen = NSScreen.main else { return }

        let text = previewState.displayText
        guard !text.isEmpty else { return }

        let textWidth = previewPanelWidth - previewHPad
        let style = NSMutableParagraphStyle()
        style.lineSpacing = previewLineSpacing

        let attrStr = NSAttributedString(
            string: text,
            attributes: [.font: previewFont, .paragraphStyle: style]
        )
        let textRect = attrStr.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        let minH = previewSingleLineHeight + previewVPad
        let maxH = previewSingleLineHeight * previewMaxLines + previewVPad
        let targetH = min(max(ceil(textRect.height) + previewVPad, minH), maxH)

        let x = screen.frame.midX - previewPanelWidth / 2
        let bottomY = screen.visibleFrame.minY + screen.visibleFrame.height * 0.15
        let newFrame = NSRect(x: x, y: bottomY, width: previewPanelWidth, height: targetH)

        if abs(panel.frame.height - targetH) > 2 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(newFrame, display: true)
            }
        }
    }

    private func _dismissPreviewPanel() {
        guard let panel = previewPanel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            self.previewPanel = nil
            self.previewState.displayText = ""
        })
    }
}

// MARK: - Transcription Preview

class TranscriptionPreviewState: ObservableObject {
    @Published var displayText: String = ""
}

struct TranscriptionPreviewView: View {
    @ObservedObject var state: TranscriptionPreviewState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                Text(state.displayText)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .id("previewEnd")
            }
            .onChange(of: state.displayText) { _ in
                proxy.scrollTo("previewEnd", anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.12, opacity: 0.88))
        )
    }
}

// MARK: - Waveform Views

struct WaveformBar: View {
    let amplitude: CGFloat

    private let minHeight: CGFloat = 3
    private let maxHeight: CGFloat = 44

    var body: some View {
        Capsule()
            .fill(.white)
            .frame(width: 3, height: minHeight + (maxHeight - minHeight) * amplitude)
    }
}

struct WaveformView: View {
    let audioLevel: Float

    private static let barCount = 9
    private static let baseMultipliers: [CGFloat] = [0.35, 0.55, 0.75, 0.9, 1.0, 0.9, 0.75, 0.55, 0.35]

    @State private var barOffsets: [CGFloat] = (0..<9).map { _ in CGFloat.random(in: -0.35...0.35) }

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                WaveformBar(amplitude: barAmplitude(for: index))
                    .animation(
                        .interpolatingSpring(stiffness: 600, damping: 28),
                        value: audioLevel
                    )
            }
        }
        .frame(height: 44)
        .onChange(of: audioLevel) { _ in
            for i in 0..<Self.barCount {
                barOffsets[i] = CGFloat.random(in: -0.35...0.35)
            }
        }
    }

    private func barAmplitude(for index: Int) -> CGFloat {
        let level = CGFloat(audioLevel)
        let base = level * Self.baseMultipliers[index]
        let varied = base + base * barOffsets[index]
        return min(max(varied, 0), 1.0)
    }
}

// MARK: - Recording Overlay View

struct InitializingDotsView: View {
    @State private var activeDot = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.white.opacity(activeDot == index ? 0.9 : 0.25))
                    .frame(width: 4.5, height: 4.5)
                    .animation(.easeInOut(duration: 0.4), value: activeDot)
            }
        }
        .onAppear {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                DispatchQueue.main.async { activeDot = (activeDot + 1) % 3 }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

struct RecordingOverlayView: View {
    @ObservedObject var state: RecordingOverlayState

    var body: some View {
        Group {
            switch state.phase {
            case .initializing:
                InitializingDotsView()
                    .transition(.opacity)
            default:
                WaveformView(audioLevel: state.audioLevel)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.phase)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Error Overlay

struct ErrorOverlayView: View {
    let title: String
    let suggestion: String

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.yellow)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
            }
            Text(suggestion)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Transcribing Indicator

struct TranscribingIndicatorView: View {
    @State private var animatingDot = 0
    @State private var dotAnimationTimer: Timer?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.white.opacity(animatingDot == index ? 0.9 : 0.25))
                    .frame(width: 4.5, height: 4.5)
                    .animation(.easeInOut(duration: 0.4), value: animatingDot)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startDotAnimation() }
        .onDisappear { stopDotAnimation() }
    }

    private func startDotAnimation() {
        dotAnimationTimer?.invalidate()
        dotAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            DispatchQueue.main.async {
                animatingDot = (animatingDot + 1) % 3
            }
        }
    }

    private func stopDotAnimation() {
        dotAnimationTimer?.invalidate()
        dotAnimationTimer = nil
    }
}
