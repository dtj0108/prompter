# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

**Prompter** — Drew's personal Wispr Flow replacement. A native macOS menu-bar dictation app: hold/tap a right-side modifier key, talk, and polished text is pasted at the cursor. Swift + SwiftUI, SwiftPM only (no Xcode project). Runs on macOS 26+, Apple Silicon.

Pipeline: hotkey (`HotkeyMonitor`) → mic (`Recorder`) → on-device STT (`STT/Transcriber.swift`, macOS 26 `SpeechAnalyzer`/`SpeechTranscriber`) → AI cleanup (`LLM/LLMClient.swift`: OpenRouter if key set, else `claude` CLI, else raw dictionary corrections) → paste (`Output/Paster.swift`) → log (`InsightsStore`). Orchestrated by `DictationController`.

## Build, install, test

```sh
swift build -c release                 # compile check
./scripts/build-app.sh --install       # build → ad-hoc sign → /Applications/Prompter.app
open /Applications/Prompter.app

# Headless verification (no mic/GUI needed):
.build/release/Prompter --transcribe /tmp/prompter-test.aiff   # STT end-to-end
.build/release/Prompter --test-llm                             # AI backend check
.build/release/Prompter --test-cleanup "um so send the uh report"
say -o /tmp/prompter-test.aiff "some words"                    # make test audio
```

After installing a rebuilt app: quit the running instance first (`pkill -x Prompter`), reinstall, `open` it again.

## Critical gotchas

- **Ad-hoc signing resets TCC**: every rebuilt binary loses Microphone/Accessibility grants. Permanent fix: create a self-signed "prompter-dev" Code Signing cert in Keychain Access once, then `./scripts/build-app.sh --identity prompter-dev --install`.
- **Accessory app + missing main menu**: the app is `LSUIElement`; ⌘V/⌘C only work in its windows because `AppDelegate.setupMainMenu()` installs a hidden Edit menu. Don't remove it.
- **Never lose the user's words**: every failure path in `DictationController`/`LLMClient` must fall back to pasting/copying the raw transcript, never dropping it.
- **Tolerant decoding**: all Codable models in `Storage/Models.swift` have custom `init(from:)` with `decodeIfPresent` per field. When adding a config/model field, add it to `CodingKeys` AND the tolerant init, or user data gets wiped on decode failure (loadJSON backs up bad files, but still).
- **Hotkeys are passive NSEvent monitors** (never swallow events). Hold = push-to-talk, tap = hands-free latch (see `HotkeyMonitor` state machine: idle → pending → active/latched). Global monitors registered before Accessibility is granted are dead until re-registered — `DictationController.start()` has a timer for this.
- **Paste rule**: paste only when the original app is still frontmost OR the focused element accepts text (`ContextDetector.focusedElementAcceptsText()`); otherwise clipboard-only with a HUD notice.
- Swift 6 concurrency is strict here; prefer `DispatchQueue.main.async` hops at boundaries (audio tap thread, AX calls, process waiters) as the existing code does.

## Data & config

All state in `~/Library/Application Support/Prompter/`: `config.json` (incl. OpenRouter key, chmod 600), `dictionary.json`, `snippets.json`, `styles.json`, `history.jsonl` (insights), `prompts/prompt-mode.md` (user-editable meta-prompt), `prompter.log` (read this first when debugging).

OpenRouter default model: `google/gemini-2.5-flash-lite` (~$0.03/day); request sends a fallback `models` array; response `usage.cost` is logged per dictation into insights.

## UI map

`UI/MainWindowView.swift` — Flow-style sidebar window (Home/Insights/Dictionary/Snippets/Style/Settings), custom `SidebarItem` rows (List's sidebar style eats hover effects). `UI/HUD.swift` — the persistent bottom-center pill with live waveform (an `NSPanel` that must never become key). `UI/OnboardingView.swift` — first-run setup assistant, gated by `config.onboardingDone`. `WindowRouter` owns all windows.
