# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Build asr-bridge (Go service bundled inside the app)
cd asr-bridge && go build -o asr-bridge .

# Build SpeakLow.app (copies asr-bridge binary into .app bundle)
cd speaklow-app && make all

# Build + launch
cd speaklow-app && make run

# Create distributable zip (requires ~/.config/speaklow/.env with API key)
cd speaklow-app && make dist
```

No test framework — use `make run` and manual testing. See `docs/TEST_PLAN.md` for test scenarios.

## Architecture

Two-process design: a **Swift menu-bar app** communicates with a **Go HTTP/WebSocket service** (asr-bridge) running on `localhost:18089`.

```
User presses hotkey → AudioRecorder captures WAV → StreamingTranscriptionService
  sends audio via WebSocket to asr-bridge → asr-bridge forwards to DashScope FunASR
  → recognized text returned → (optional) LLM refinement via /v1/refine
  → TextInserter inserts at cursor (AX API → clipboard+Cmd+V → copy-only fallback)
```

### Swift App (`speaklow-app/Sources/`)

- **AppState.swift** — Central orchestrator. Recording lifecycle, streaming delegation, error handling, self-healing (bridge restart, audio engine rebuild). Largest file (~37KB).
- **ASRBridgeManager.swift** — Manages Go bridge process lifecycle (launch, health check, restart).
- **AudioRecorder.swift** — AVAudioEngine microphone capture with silence detection.
- **HotkeyManager.swift** — Global hotkey monitoring (Right Option / Fn / F5).
- **StreamingTranscriptionService.swift** — WebSocket client for real-time ASR via `/v1/stream`.
- **TranscriptionService.swift** — Batch HTTP transcription via `/v1/transcribe`.
- **TextInserter.swift** — Three-tier text insertion: AX API direct write → clipboard+Cmd+V paste → notification with copy. AX write is verified by read-back (Electron apps report success but don't write).
- **TextRefineService.swift** — Calls `/v1/refine` for LLM text polishing.
- **RecordingOverlay.swift** — Notch-area waveform overlay + text result fallback panel (shown when AX/paste insertion fails). Contains both SwiftUI views and `RecordingOverlayManager` (panel lifecycle, notch-aware positioning).

### Go Bridge (`asr-bridge/`)

HTTP service with endpoints: `/health`, `/v1/transcribe`, `/v1/stream` (WebSocket), `/v1/refine`.

Built on [audio-asr-suite](../../../组件模块/audio-asr-suite) modules:
- `pkg/realtime.Module` — DashScope WebSocket ASR protocol
- `pkg/hotword.Manager` — Custom vocabulary management

The suite is referenced via `go.mod replace` directive pointing to `../../../组件模块/audio-asr-suite/go/audio-asr-go`.

## Configuration

API key lookup order: env var `DASHSCOPE_API_KEY` → `~/.config/speaklow/.env` → `.env` next to binary.

Key env vars: `ASR_BRIDGE_PORT` (default 18089), `ASR_MODEL` (default paraformer-realtime-v2).

## Platform Constraints

- macOS 13.0+, universal binary (ARM64/x86_64)
- Compiled with `swiftc` directly (no Xcode project/SPM)
- Accessibility API (`AXUIElementCreateApplication`) is unreliable — `AXIsProcessTrusted()` flickers between true/false; the app does not block recording on this check
- Electron apps (VS Code, Slack) accept AX writes silently but don't apply them — TextInserter verifies by read-back
- Clipboard paste fallback (`Cmd+V`) also fails silently when AX permissions are denied — must check `AXIsProcessTrusted()` before assuming paste succeeded

## Conventions

- Language: Chinese UI strings, Chinese comments, Chinese error messages
- Logging: `os_log` to `~/Library/Logs/SpeakLow.log`
- Settings: `UserDefaults` for user preferences (LLM mode, hotkey, microphone)
- Secrets: `KeychainStorage` for API keys in the app; `.env` files for the bridge

## Debugging

- Logs: `~/Library/Logs/SpeakLow.log` (uses `os_log`, viewable in Console.app or `log stream --predicate 'subsystem == "com.speaklow.app"'`)
- Streaming stall: AppState has a 3-second repeating timer that auto-finishes if partial text is unchanged for 10 seconds
- Safety timeout: 5-second fallback timer fires after `stopStreamingRecording` to prevent indefinite hang
- Bridge health: `curl http://localhost:18089/health` — if unhealthy, ASRBridgeManager auto-restarts the Go process
