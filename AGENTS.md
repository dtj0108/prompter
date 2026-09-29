# AGENTS.md

Guidance for Codex when working in this repository.

## Project routing

Prompter lives at `/Users/andrewbaskin/prompter` and is a separate Git
repository. Work here when the user says **Prompter**, **dictation**,
**voice-to-text**, or **Prompt Mode**.

The related Ambitious products live in `/Users/andrewbaskin/ambitious`:

- Ambitious Social: `apps/mobile`, `apps/web`, and `apps/admin`.
- Ambitious Mail: `apps/ambitious-mail`.
- Ambitious Browse: `apps/ambitious-browse`.

Prompter depends on Ambitious only for identity and its branded OAuth entry
routes. A request about the Prompter client belongs here; a request about the
web OAuth routes belongs in the Ambitious repo; a true end-to-end sign-in
change may require coordinated, separate changes in both repositories. If the
intended product cannot be established from context, ask the user before
editing.

## What this is

**Prompter** — Drew's personal Wispr Flow replacement. A native macOS Dock dictation app: hold/tap a right-side modifier key, talk, and polished text is pasted at the cursor. Swift + SwiftUI, SwiftPM only (no Xcode project). Runs on macOS 26+, Apple Silicon.

Pipeline: cached Ambitious identity gate → hotkey (`HotkeyMonitor`) → mic (`Recorder`) → GPT Live Transcribe (`STT/OpenAIRealtimeTranscriber.swift`) → optional AI cleanup (`LLM/LLMClient.swift`) → output → log (`InsightsStore`). GPT Live Transcribe is the only speech engine and requires an OpenAI key plus internet access. No Apple or OpenRouter STT fallback and no temporary microphone WAV. `liveTypingEnabled` defaults to false; when enabled, regular dictation updates a validated Accessibility text range through `Output/LiveTextSession.swift`. Prompt Mode still inserts only the completed rewrite. The auth gate performs no network work in this hot path.

## Build, install, test

```sh
swift build -c release                 # compile check
./scripts/build-app.sh --install       # build → ad-hoc sign → /Applications/Prompter.app
open /Applications/Prompter.app

# Headless verification (no mic/GUI needed):
.build/release/Prompter --transcribe /tmp/prompter-test.aiff   # STT end-to-end
.build/release/Prompter --test-stream-openai /tmp/test.aiff    # paced live GPT stream
.build/release/Prompter --test-llm                             # AI backend check
.build/release/Prompter --test-cleanup "um so send the uh report"
say -o /tmp/prompter-test.aiff "some words"                    # make test audio
```

After installing a rebuilt app: quit the running instance first (`pkill -x Prompter`), reinstall, `open` it again.

## Critical gotchas

- **Ad-hoc signing resets TCC**: every rebuilt binary loses Microphone/Accessibility grants. Permanent fix: create a self-signed "prompter-dev" Code Signing cert in Keychain Access once, then `./scripts/build-app.sh --identity prompter-dev --install`.
- **System Settings deep links need the modern pane id**: use `SystemSettingsPrivacyPane` (`x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_…`). The legacy `com.apple.preference.security` id silently ignores the anchor on macOS 26 and strands the user on the wrong privacy subpage.
- **Headless commands suppress Keychain UI** (`HeadlessCLI`): a dev/CI binary signed differently from the installed app would otherwise hang forever on a hidden keychain consent prompt when touching the Ambitious session item. CLI runs therefore see the item as absent (signed out); that's by design.
- **Main menu is programmatic**: there is no storyboard, so `AppDelegate.setupMainMenu()` provides the app, Edit, Navigate, and Window menus. Keep the Edit menu so standard ⌘V/⌘C shortcuts continue to work.
- **Live output ownership**: replace only the dictated range after checking field identity, complete expected text, and caret. Any mismatch suspends updates permanently for that session; copy the finished transcript instead of appending it again. Unsupported fields use ordinary final paste. Cancellation leaves already inserted words. A stream failure preserves received GPT deltas and reports partial recovery; never switch speech models.
- **Never lose the user's words**: every failure path in `DictationController`/`LLMClient` must fall back to pasting/copying the raw transcript, never dropping it.
- **Tolerant decoding**: all Codable models in `Storage/Models.swift` have custom `init(from:)` with `decodeIfPresent` per field. When adding a config/model field, add it to `CodingKeys` AND the tolerant init, or user data gets wiped on decode failure (loadJSON backs up bad files, but still).
- **Multiple shortcuts**: each mode keeps its original primary key plus `additionalDictationHotkeys` / `additionalPromptHotkeys` arrays. Settings supports adding, editing, and removing shortcuts; keep at least one per mode. Compare semantic key/button identities, prevent duplicate assignments, and preserve extras when onboarding edits the primary. Any shortcut for the same mode stops hands-free recording; a held recording ends when its initiating shortcut is released. Finishing presses stay in `releasing` state until key/button release; normal commits must not reset that guard. Live typing recognizes all shortcuts for its mode.
- **Hotkeys are passive NSEvent monitors** (never swallow events). Hold = push-to-talk, tap = hands-free latch (see `HotkeyMonitor` state machine: idle → pending → active/latched). Global monitors registered before Accessibility is granted are dead until re-registered — `DictationController.start()` has a timer for this.
- **Paste rule**: paste by default — same app, confirmed text cursor, or when accessibility can't tell (`ContextDetector.focusedTextTarget()` returns `.unknown`). Clipboard-only with a HUD notice ONLY when focus provably rejects text (`.rejectsText`: desktop, a button, …) or a secure field is active.
- Swift 6 concurrency is strict here; prefer `DispatchQueue.main.async` hops at boundaries (audio tap thread, AX calls, process waiters) as the existing code does.

## Data & config

Editable app state lives in `~/Library/Application Support/Prompter/`: `config.json` (incl. OpenRouter key, chmod 600), `dictionary.json`, `snippets.json`, `styles.json`, `history.jsonl` (insights), `prompts/prompt-mode.md` (user-editable meta-prompt), `prompter.log` (read this first when debugging). Ambitious identity and OAuth tokens live only in the macOS Keychain under `com.drew.prompter.ambitious`; never log an authorization code, token, or full OAuth callback URL. Release sign-in enters the browser flow at the branded `https://www.ambitious.social/oauth/prompter/start` route (deployed from the ambitious monorepo) so no user-visible surface shows the Supabase issuer host; see SIGN_IN_WITH_AMBITIOUS.md before touching the flow.

GPT Live Transcribe is fixed as the only speech model; obsolete engine configuration keys are ignored on decode. Text cleanup and Prompt Mode default to the low-latency `google/gemini-3.1-flash-lite`. STT and cleanup `usage.cost` values are both logged per dictation into insights.

Public updates are built by `.github/workflows/publish-update.yml` on pushes to `main`. The workflow requires the Developer ID and notarization secrets documented in README, and must never fall back to ad-hoc signing: a changing code identity resets Microphone and Accessibility grants. It publishes `Prompter.zip` plus `update.json` to GitHub Releases. `AppUpdater` checks the public repository embedded as `PrompterUpdateRepository`; never embed a GitHub token in the app.

## UI map

`UI/MainWindowView.swift` — Flow-style sidebar window (Home/Insights/Dictionary/Snippets/Style/Settings), custom `SidebarItem` rows (List's sidebar style eats hover effects). `UI/HUD.swift` — the persistent bottom-center pill with live waveform (an `NSPanel` that must never become key). `UI/OnboardingView.swift` — Ambitious-branded sign-in + onboarding (five designed intro/sign-in screens, then the permission/hotkey/AI setup steps in the same style) in a chromeless 680×640 window, gated by `config.onboardingDone`; reopen entry points are `OnboardingStep` cases (`.signIn`, `.microphone`, `.accessibility`), design tokens live in `UI/AmbitiousDesign.swift`. Signed-out users must never reach the app: `WindowRouter.openMain` bounces to the sign-in step without an Ambitious identity, sign-out closes the main window, and onboarding offers no exit ("Return to Prompter" requires `isSignedIn`). `WindowRouter` owns all windows.
