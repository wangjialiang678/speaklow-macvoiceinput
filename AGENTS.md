# AGENTS.md

This file provides guidance to AI coding assistants (Claude Code, Codex, Cursor, etc.) when working with this repository.

## First-Time Installation Guide

**If the user is installing SpeakLow for the first time, follow these steps in order.** This is a macOS voice input tool — hold a hotkey to speak, release to insert text at the cursor.

### Step 1: Check Prerequisites

```bash
# Check macOS version (need 13.0+)
sw_vers

# Check Xcode Command Line Tools
xcode-select -p
# If not installed: xcode-select --install

# Check Go version (need 1.22+)
go version
# If not installed: brew install go
# If Homebrew not installed: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### Step 2: Get a DashScope API Key

SpeakLow uses Alibaba Cloud DashScope for speech recognition. The user needs their own API key.

1. Go to https://dashscope.console.aliyun.com/ and sign up (Chinese phone number required for Alibaba Cloud)
2. After login, go to **API-KEY 管理** (API Key Management) in the left sidebar
3. Click **创建新的 API-KEY** (Create New API Key)
4. Copy the key (starts with `sk-`)

Then save it:
```bash
mkdir -p ~/.config/speaklow
echo 'DASHSCOPE_API_KEY=sk-your-key-here' > ~/.config/speaklow/.env
```

**Important:** DashScope offers a free tier with generous quotas for qwen3-asr-flash and qwen-flash models. No payment setup needed for normal personal use.

### Step 3: Build and Install

```bash
cd speaklow-app && make run
```

This single command builds everything (Go bridge + Swift app) and launches the app. First build takes ~30 seconds.

### Step 4: Grant System Permissions

On first launch, macOS will ask for two permissions:

1. **Microphone** — a system dialog pops up, click "OK"
2. **Accessibility** — needed for auto-inserting text at cursor position:
   - Open **System Settings → Privacy & Security → Accessibility**
   - Click the lock icon to unlock
   - Click "+" and add **SpeakLow.app** (in `speaklow-app/build/`)
   - Make sure the toggle is ON

If accessibility is not granted, the app still works but you'll need to manually paste (Cmd+V) after each recognition.

### Step 5: Verify It Works

1. Look for the SpeakLow icon in the **menu bar** (top-right of screen)
2. **Hold the Right Option key** (⌥, right side of keyboard) and speak
3. **Release** — text should appear at the cursor position
4. If text doesn't insert automatically, check accessibility permission (Step 4)

### Step 6: Customize Hotwords (Optional)

The app comes with ~70 AI development terms pre-loaded. To add your own terms:

- Open the app's **Settings** (click menu bar icon) → scroll to **Hotwords** section → click "编辑热词..."
- Or edit the file directly: `~/.config/speaklow/hotwords.txt`

### Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| "SpeakLow is damaged" on first open | macOS Gatekeeper | Run `xattr -cr speaklow-app/build/SpeakLow.app` |
| No menu bar icon | App didn't launch | Check `make run` output for build errors |
| Records but text doesn't insert | Accessibility permission missing | See Step 4 |
| "语音服务未启动" error | Bridge not running | Restart the app; check `~/.config/speaklow/.env` has valid API key |
| Records but empty result | Wrong microphone selected | Click menu bar icon → Settings → change microphone |
| Build fails at `go build` | Go not installed or < 1.22 | `brew install go` or `brew upgrade go` |
| Build fails at `swiftc` | Xcode CLI tools missing | `xcode-select --install` |

### Logs for Debugging

- App log: `~/Library/Logs/SpeakLow.log`
- Recorded audio: `~/Library/Caches/SpeakLow/recordings/` (last 20 files)
- Bridge health: `curl http://localhost:18089/health`

---

## Build & Run (Developer Reference)

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

**Streaming mode:** Swift communicates with a **Go HTTP/WebSocket service** (asr-bridge) on `localhost:18089`.
```
User presses hotkey → AudioRecorder captures PCM
  → StreamingTranscriptionService sends audio via WebSocket to asr-bridge /v1/stream
  → asr-bridge forwards to DashScope qwen3-asr-flash-realtime (OpenAI Realtime API protocol)
  → Real-time partial/final text displayed in RecordingOverlay preview
  → On release: final text from streaming result
  → (optional) DashScopeClient.refine() → qwen-flash LLM (direct DashScope call)
  → TextInserter inserts at cursor (AX API → clipboard+Cmd+V → copy-only fallback)
```

**Batch mode (default):** Swift directly calls DashScope REST API. No Go bridge needed.
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

HTTP service with endpoints: `/health`, `/v1/stream` (WebSocket), `/v1/transcribe-sync`, `/v1/refine`, `/v1/reload-hotwords`.

- **main.go** — HTTP routing, CORS/logging middleware, service initialization, API key loading
- **stream.go** — WebSocket streaming transcription. Three-way relay: Swift client ↔ Bridge ↔ DashScope qwen3-asr-flash-realtime (OpenAI Realtime API protocol via `wss://dashscope.aliyuncs.com/api-ws/v1/realtime`)
- **transcribe_sync.go** — qwen3-asr-flash synchronous REST API transcription (base64 audio, multimodal-generation endpoint)
- **hotword.go** — Hotword loading from `Resources/hotwords.txt`, builds corpus text for qwen3 system message
- **refine.go** — LLM text refinement (qwen-turbo-latest via DashScope OpenAI-compatible API)
- **env.go** — `.env` file loading with priority chain

Dependencies: `gorilla/websocket` + `godotenv` (no external ASR framework dependency).

## Configuration

API key lookup order: env var `DASHSCOPE_API_KEY` → `~/.config/speaklow/.env` → `.env` next to binary.

Hotword file lookup order: env var `HOTWORDS_FILE` → `~/.config/speaklow/hotwords.txt` → bundle `Resources/hotwords.txt`. Runtime reload: `speaklow-reload-hotwords` CLI (or `POST /v1/reload-hotwords` for bridge, `DistributedNotification "com.speaklow.reloadHotwords"` for app).

Key env vars:
- `ASR_BRIDGE_PORT` (default 18089) — bridge HTTP port
- `ASR_MODEL` (default qwen3-asr-flash-realtime) — streaming ASR model
- `ASR_SYNC_MODEL` (default qwen3-asr-flash) — sync second-pass ASR model

## Platform Constraints

- macOS 13.0+, universal binary (ARM64/x86_64)
- Compiled with `swiftc` directly (no Xcode project/SPM)
- **Accessibility permission detection**: `AXIsProcessTrusted()` is unreliable — returns true even when CGEvent posting is silently dropped (stale permission after recompile). The app uses `CGEvent.tapCreate()` at launch for runtime verification (see `docs/design/2026-03-09-accessibility-permission-detection.md`)
- Electron apps (VS Code, Slack) accept AX writes silently but don't apply them — TextInserter verifies by read-back
- Clipboard paste fallback (`Cmd+V`) via CGEvent is silently dropped when AX permissions are stale — TextInserter verifies paste success by comparing AX value length before/after with 250ms delay. AXWebArea (VS Code webview) always returns empty value; treated as inconclusive (assume success)

## Conventions

- Language: Chinese UI strings, Chinese comments, Chinese error messages
- Logging: `os_log` to `~/Library/Logs/SpeakLow.log`
- Settings: `UserDefaults` for user preferences (LLM mode, hotkey, microphone, ASR mode)
- Secrets: `KeychainStorage` for API keys in the app; `.env` files for the bridge
- **Strategy pattern for behavioral variants**: When the same flow has multiple implementations (e.g., batch vs streaming ASR), use protocol + concrete implementations to encapsulate differences. The main flow calls through the protocol interface, not `if mode == X` branches
- **Configuration-driven, not hardcoded**: Mode selection, feature toggles use UserDefaults. Code creates the appropriate strategy instance based on config

## Known Pitfalls

- **`open SpeakLow.app` does NOT restart a running app** — macOS `open` brings the existing process to front. `make run` now kills existing `SpeakLow` / `asr-bridge` processes before opening the freshly built app, but manual `open build/SpeakLow.app` still has the stale-process pitfall.

## Debugging

- Logs: `~/Library/Logs/SpeakLow.log` (uses `os_log`, viewable in Console.app or `log stream --predicate 'subsystem == "com.speaklow.app"'`)
- Recorded audio: `~/Library/Caches/SpeakLow/recordings/` (last 20 files, named `recording-yyyyMMdd-HHmmss.wav`)
- Safety timeout: 5-second fallback timer fires after `stopStreamingRecording` to prevent indefinite hang (user controls recording lifecycle; no auto-finish during recording)
- Bridge health: `curl http://localhost:18089/health` — if unhealthy, ASRBridgeManager auto-restarts the Go process

## Documentation Index

### Specs
- `docs/specs/prd.md` — Product requirements
- `docs/specs/architecture.md` — System architecture
- `docs/specs/test-plan.md` — Test scenarios and manual test plan

### Design Decisions
- `docs/design/2026-03-11-hotword-runtime-reload.md` — Hotword runtime reload (CLI + DistributedNotification + HTTP endpoint)
- `docs/design/2026-03-09-accessibility-permission-detection.md` — AX permission runtime check via CGEvent.tapCreate()
- `docs/design/2026-03-08-app-icon-design.md` — App icon design
- `docs/design/2026-03-07-settings-ui-redesign.md` — Settings UI full rewrite
- `docs/design/2026-03-06-batch-asr-strategy.md` — Batch/streaming dual-mode Strategy pattern design
- `docs/design/2026-03-06-remote-diagnostics.md` — Remote diagnostics feature
- `docs/design/2026-03-05-optimization-plan.md` — ASR optimization plan (qwen3 migration)
- `docs/design/2026-03-05-migrate-qwen3-realtime.md` — Migration from paraformer to qwen3
- `docs/design/2026-03-02-asr-suite-integration.md` — audio-asr-suite integration proposal
- `docs/design/2026-03-02-hotwords-maintenance.md` — Hotword maintenance workflow

### Research
- `docs/research/2026-03-05-asr-models-comparison.md` — DashScope ASR model comparison (qwen3 vs paraformer)
- `docs/research/2026-03-01-streaming-text-insertion.md` — Streaming text insertion feasibility (AX API on native vs Electron)
- `docs/research/macos-settings-ui-design-reference.md` — macOS Settings UI design patterns

### Reusable ASR Guide (for other teams)
- `docs/reusable-asr-guide/README.md` — Overview: two modes, quick start
- `docs/reusable-asr-guide/01-dashscope-asr-api-reference.md` — Batch REST + streaming WebSocket + hotword API
- `docs/reusable-asr-guide/02-llm-refine-api-reference.md` — LLM post-processing (qwen-flash, prompt injection defense)
- `docs/reusable-asr-guide/03-audio-format-spec.md` — 16kHz mono PCM, format conversion, silence detection
- `docs/reusable-asr-guide/04-reusable-modules.md` — Go bridge copy guide, file list, what to modify
- `docs/reusable-asr-guide/05-pitfalls-and-solutions.md` — 8 pitfalls ranked P0-P3 (corpus leak, hallucination, etc.)

### User Handbook
- `docs/handbook/install-guide.md` — Installation guide
- `docs/handbook/how-it-works.md` — How it works (end-user)
- `docs/handbook/tutorial.md` — Development tutorial
- `docs/handbook/hotwords-ai-dev.md` — Hotword list explanation

### Logs & Reviews
- `docs/logs/dev-log.md` — Development log
- `docs/logs/2026-03-06-corpus-leak-investigation.md` — Corpus text echo-back root cause analysis
- `docs/reviews/code-review-2026-03-06.md` — Code review
- `docs/reviews/2026-03-06-batch-asr-code-review.md` — Batch ASR code review

## Source Code Map

### Swift App (`speaklow-app/Sources/` — 20 files, compiled via single `swiftc` invocation)

**Core flow:**
- `AppState.swift` — Central orchestrator (recording lifecycle, ASR dispatch, error handling)
- `AppDelegate.swift` — App launch, permission checks, bridge startup
- `App.swift` — SwiftUI app entry point

**ASR:**
- `DashScopeClient.swift` — Direct DashScope API client (batch ASR + LLM refine + hotword corpus)
- `TranscriptionStrategy.swift` — Strategy protocol + ASRMode enum + BatchStrategy + StreamingStrategy
- `StreamingTranscriptionService.swift` — WebSocket client for bridge `/v1/stream`
- `TranscriptionService.swift` — HTTP client for bridge `/v1/transcribe-sync`

**Audio:**
- `AudioRecorder.swift` — AVAudioEngine capture, PCM conversion, silence detection, file retention

**Text output:**
- `TextInserter.swift` — Three-tier insertion (AX → clipboard+paste → copy-only)
- `TextRefineService.swift` — LLM refine wrapper (RefineStyle enum)

**UI:**
- `RecordingOverlay.swift` — Notch waveform + text fallback panel
- `MenuBarView.swift` — Menu bar status item
- `SettingsView.swift` — Settings window (ASR mode, hotkey, microphone, LLM toggle)
- `SetupView.swift` — First-run setup
- `HotwordEditor.swift` — Inline hotword list editor

**Infrastructure:**
- `HotkeyManager.swift` — Global hotkey monitoring (Right Option / Fn / F5)
- `ASRBridgeManager.swift` — Go bridge process lifecycle (launch, health, restart)
- `EnvLoader.swift` — Environment variable loader
- `DiagnosticRunner.swift` — Self-check diagnostics
- `DiagnosticExporter.swift` — Export diagnostic report

### Go Bridge (`asr-bridge/` — 7 files, 2 dependencies)

- `main.go` — HTTP server, routing, CORS, logging, log rotation, `/v1/reload-hotwords` endpoint
- `stream.go` — WebSocket streaming (Swift ↔ Bridge ↔ DashScope three-way relay)
- `transcribe_sync.go` — Batch REST transcription (base64 audio → DashScope)
- `hotword.go` — Hotword file loading, corpus text construction, runtime reload (`reloadHotwords()`)
- `hotword_test.go` — Hotword loading and reload unit tests (9 test cases)
- `refine.go` — LLM refinement (DashScope OpenAI-compatible API)
- `refine_test.go` — Refine unit tests
- `env.go` — `.env` file loading (priority chain)

### Scripts (`scripts/`)

- `speaklow-reload-hotwords` — CLI tool to reload hotwords (bridge HTTP + app DistributedNotification)

### Resources (`speaklow-app/Resources/`)

- `hotwords.txt` — ~70 AI dev terms (tab-separated: word, weight, src_lang, target_lang)
- `refine_preamble.txt` — LLM safety preamble (immutable, bundled)
- `refine_prompt.txt` — LLM refinement rules (user-overridable via `~/.config/speaklow/`)
- `AppIcon.icns` — App icon
- `AppIcon-Source.png` — App icon source image
