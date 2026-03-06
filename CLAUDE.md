# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

Prerequisites: macOS 13.0+, Xcode Command Line Tools, Go 1.22+.

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

### Testing

No Swift test framework — use `make run` and manual testing. See `docs/specs/test-plan.md` for test scenarios.

Go bridge has unit tests:
```bash
cd asr-bridge && go test ./...
```

## Architecture

Dual-mode design: a **Swift menu-bar app** with two ASR modes selectable in Settings.

**Streaming mode (default):** Swift communicates with a **Go HTTP/WebSocket service** (asr-bridge) on `localhost:18089`.
```
User presses hotkey → AudioRecorder captures PCM
  → StreamingTranscriptionService sends audio via WebSocket to asr-bridge /v1/stream
  → asr-bridge forwards to DashScope qwen3-asr-flash-realtime (OpenAI Realtime API protocol)
  → Real-time partial/final text displayed in RecordingOverlay preview
  → On release: final text from streaming result
  → (optional) DashScopeClient.refine() → qwen-flash LLM (direct DashScope call)
  → TextInserter inserts at cursor (AX API → clipboard+Cmd+V → copy-only fallback)
```

**Batch mode:** Swift directly calls DashScope REST API. No Go bridge needed.
```
User presses hotkey → AudioRecorder captures PCM → saves WAV
  → On release: DashScopeClient.transcribe() → qwen3-asr-flash REST API (base64 audio)
  → (optional) DashScopeClient.refine() → qwen-flash LLM (direct DashScope call)
  → TextInserter inserts at cursor (AX API → clipboard+Cmd+V → copy-only fallback)
```

Bridge is auto-started in streaming mode and auto-stopped when switching to batch. Mode switch in Settings takes effect immediately.

### Swift App (`speaklow-app/Sources/`)

Compiled with `swiftc` directly (no Xcode project/SPM). All 17 `.swift` files are passed to a single `swiftc` invocation via the Makefile.

Key files:
- **AppState.swift** — Central orchestrator. Recording lifecycle, dual-mode ASR (batch/streaming), error handling, self-healing. Largest file.
- **DashScopeClient.swift** — Swift direct DashScope API client: batch ASR (qwen3-asr-flash), LLM refine (qwen-flash), hotword corpus loading. Singleton.
- **TranscriptionStrategy.swift** — Strategy protocol + ASRMode enum + BatchStrategy + StreamingStrategy.
- **ASRBridgeManager.swift** — Go bridge process lifecycle (launch, health check, crash auto-restart, periodic health monitor).
- **AudioRecorder.swift** — AVAudioEngine microphone capture with silence detection. Saves recordings to `~/Library/Caches/SpeakLow/recordings/` (retains last 20).
- **HotkeyManager.swift** — Global hotkey monitoring (Right Option / Fn / F5).
- **StreamingTranscriptionService.swift** — WebSocket client for real-time ASR via `/v1/stream` (streaming mode only).
- **TranscriptionService.swift** — Bridge HTTP transcription via `/v1/transcribe-sync` (streaming mode sync re-transcription).
- **TextInserter.swift** — Three-tier text insertion: AX API direct write → clipboard+Cmd+V paste → notification with copy. AX write is verified by read-back (Electron apps report success but don't write). Cmd+V paste is verified by 250ms delayed AX value read-back — catches CGEvent silently dropped by macOS (e.g., after app update when permissions are in intermediate state).
- **TextRefineService.swift** — RefineStyle enum + thin wrapper delegating to DashScopeClient.
- **RecordingOverlay.swift** — Notch-area waveform overlay + text result fallback panel (shown when AX/paste insertion fails). Contains both SwiftUI views and `RecordingOverlayManager` (panel lifecycle, notch-aware positioning).

### Go Bridge (`asr-bridge/`)

HTTP service with endpoints: `/health`, `/v1/stream` (WebSocket), `/v1/transcribe-sync`, `/v1/refine`.

- **main.go** — HTTP routing, CORS/logging middleware, service initialization, API key loading
- **stream.go** — WebSocket streaming transcription. Three-way relay: Swift client ↔ Bridge ↔ DashScope qwen3-asr-flash-realtime (OpenAI Realtime API protocol via `wss://dashscope.aliyuncs.com/api-ws/v1/realtime`)
- **transcribe_sync.go** — qwen3-asr-flash synchronous REST API transcription (base64 audio, multimodal-generation endpoint)
- **hotword.go** — Hotword loading from `Resources/hotwords.txt`, builds corpus text for qwen3 system message
- **refine.go** — LLM text refinement (qwen-turbo-latest via DashScope OpenAI-compatible API)
- **env.go** — `.env` file loading with priority chain

Dependencies: `gorilla/websocket` + `godotenv` (no external ASR framework dependency).

## Configuration

API key lookup order: env var `DASHSCOPE_API_KEY` → `~/.config/speaklow/.env` → `.env` next to binary.

Key env vars:
- `ASR_BRIDGE_PORT` (default 18089) — bridge HTTP port
- `ASR_MODEL` (default qwen3-asr-flash-realtime) — streaming ASR model
- `ASR_SYNC_MODEL` (default qwen3-asr-flash) — sync second-pass ASR model

## Platform Constraints

- macOS 13.0+, universal binary (ARM64/x86_64)
- Compiled with `swiftc` directly (no Xcode project/SPM)
- Accessibility API (`AXUIElementCreateApplication`) is unreliable — `AXIsProcessTrusted()` flickers between true/false; the app does not block recording on this check
- Electron apps (VS Code, Slack) accept AX writes silently but don't apply them — TextInserter verifies by read-back
- Clipboard paste fallback (`Cmd+V`) via CGEvent is silently dropped when AX permissions are in intermediate state (e.g., after app update) — `AXIsProcessTrusted()` may return true but events are still dropped. TextInserter verifies paste success by comparing AX value length before/after with 250ms delay

## Conventions

- Language: Chinese UI strings, Chinese comments, Chinese error messages
- Logging: `os_log` to `~/Library/Logs/SpeakLow.log`
- Settings: `UserDefaults` for user preferences (LLM mode, hotkey, microphone, ASR mode)
- Secrets: `KeychainStorage` for API keys in the app; `.env` files for the bridge
- **Strategy pattern for behavioral variants**: When the same flow has multiple implementations (e.g., batch vs streaming ASR), use protocol + concrete implementations to encapsulate differences. The main flow calls through the protocol interface, not `if mode == X` branches
- **Configuration-driven, not hardcoded**: Mode selection, feature toggles use UserDefaults. Code creates the appropriate strategy instance based on config

## Known Pitfalls

- **`make run` / `open SpeakLow.app` does NOT restart a running app** — macOS `open` brings the existing process to front. After rebuilding, you MUST `pkill -f SpeakLow` first, then `open build/SpeakLow.app` (or `make run`). Otherwise the old binary keeps running with stale code. This is a common source of "my fix doesn't work" confusion.

## Debugging

- Logs: `~/Library/Logs/SpeakLow.log` (uses `os_log`, viewable in Console.app or `log stream --predicate 'subsystem == "com.speaklow.app"'`)
- Recorded audio: `~/Library/Caches/SpeakLow/recordings/` (last 20 files, named `recording-yyyyMMdd-HHmmss.wav`)
- Streaming stall: AppState has a 3-second repeating timer that auto-finishes if partial text is unchanged for 10 seconds
- Safety timeout: 5-second fallback timer fires after `stopStreamingRecording` to prevent indefinite hang
- Bridge health: `curl http://localhost:18089/health` — if unhealthy, ASRBridgeManager auto-restarts the Go process
