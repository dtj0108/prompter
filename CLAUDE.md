# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

**Prompter** — Drew's personal Wispr Flow replacement. A native macOS Dock dictation app: hold/tap a right-side modifier key, talk, and polished text is pasted at the cursor. Swift + SwiftUI, SwiftPM only (no Xcode project). Runs on macOS 26+, Apple Silicon.

Pipeline: hotkey (`HotkeyMonitor`) → mic (`Recorder`) → macOS 26 `SpeechAnalyzer` local STT by default (or opt-in Whisper Turbo through `STT/OpenRouterTranscriber.swift`, which also records a temporary native-format WAV) → optional AI cleanup (`LLM/LLMClient.swift`) → paste (`Output/Paster.swift`) → log (`InsightsStore`). Orchestrated by `DictationController`; temporary audio is deleted after each request.

## Build, install, test

```sh
swift build -c release                 # compile check
./scripts/build-app.sh --install       # build → ad-hoc sign → /Applications/Prompter.app
open /Applications/Prompter.app

# Headless verification (no mic/GUI needed):
.build/release/Prompter --transcribe /tmp/prompter-test.aiff   # STT end-to-end
.build/release/Prompter --transcribe-openrouter /tmp/test.wav  # OpenRouter Whisper STT
.build/release/Prompter --test-llm                             # AI backend check
.build/release/Prompter --test-cleanup "um so send the uh report"
say -o /tmp/prompter-test.aiff "some words"                    # make test audio
```

After installing a rebuilt app: quit the running instance first (`pkill -x Prompter`), reinstall, `open` it again.

## Critical gotchas

- **Ad-hoc signing resets TCC**: every rebuilt binary loses Microphone/Accessibility grants. Permanent fix: create a self-signed "prompter-dev" Code Signing cert in Keychain Access once, then `./scripts/build-app.sh --identity prompter-dev --install`.
- **Main menu is programmatic**: there is no storyboard, so `AppDelegate.setupMainMenu()` provides the app, Edit, Navigate, and Window menus. Keep the Edit menu so standard ⌘V/⌘C shortcuts continue to work.
- **Never lose the user's words**: every failure path in `DictationController`/`LLMClient` must fall back to pasting/copying the raw transcript, never dropping it.
- **Tolerant decoding**: all Codable models in `Storage/Models.swift` have custom `init(from:)` with `decodeIfPresent` per field. When adding a config/model field, add it to `CodingKeys` AND the tolerant init, or user data gets wiped on decode failure (loadJSON backs up bad files, but still).
- **Hotkeys are passive NSEvent monitors** (never swallow events). Hold = push-to-talk, tap = hands-free latch (see `HotkeyMonitor` state machine: idle → pending → active/latched). Global monitors registered before Accessibility is granted are dead until re-registered — `DictationController.start()` has a timer for this.
- **Paste rule**: paste by default — same app, confirmed text cursor, or when accessibility can't tell (`ContextDetector.focusedTextTarget()` returns `.unknown`). Clipboard-only with a HUD notice ONLY when focus provably rejects text (`.rejectsText`: desktop, a button, …) or a secure field is active.
- Swift 6 concurrency is strict here; prefer `DispatchQueue.main.async` hops at boundaries (audio tap thread, AX calls, process waiters) as the existing code does.

## Data & config

All state in `~/Library/Application Support/Prompter/`: `config.json` (incl. OpenRouter key, chmod 600), `dictionary.json`, `snippets.json`, `styles.json`, `history.jsonl` (insights), `prompts/prompt-mode.md` (user-editable meta-prompt), `prompter.log` (read this first when debugging).

OpenRouter transcription is opt-in and uses `openai/whisper-large-v3-turbo`; local Apple STT is the default. Text cleanup and Prompt Mode default to the low-latency `google/gemini-3.1-flash-lite`. STT and cleanup `usage.cost` values are both logged per dictation into insights.

Public updates are built by `.github/workflows/publish-update.yml` on pushes to `main`. The workflow requires the Developer ID and notarization secrets documented in README, and must never fall back to ad-hoc signing: a changing code identity resets Microphone and Accessibility grants. It publishes `Prompter.zip` plus `update.json` to GitHub Releases. `AppUpdater` checks the public repository embedded as `PrompterUpdateRepository`; never embed a GitHub token in the app.

## UI map

`UI/MainWindowView.swift` — Flow-style sidebar window (Home/Insights/Dictionary/Snippets/Style/Settings), custom `SidebarItem` rows (List's sidebar style eats hover effects). `UI/HUD.swift` — the persistent bottom-center pill with live waveform (an `NSPanel` that must never become key). `UI/OnboardingView.swift` — first-run setup assistant, gated by `config.onboardingDone`. `WindowRouter` owns all windows.
