# Prompter

A personal, $0/month replacement for Wispr Flow. Hold a key, talk, release — polished text appears wherever your cursor is.

Built as a native macOS menu-bar app. Speech-to-text runs **fully on-device** (Apple's macOS 26 `SpeechAnalyzer` — your audio never leaves the Mac). The AI cleanup runs through **Claude** — via the `claude` CLI on your existing subscription (default, no extra cost) or the Anthropic API if you add a key in Settings.

## What it does

- **Dictation** — hold **Right ⌥ Option**, talk, release. Prompter transcribes, cleans up filler/self-corrections, applies your dictionary and style, and pastes at your cursor. Tap Esc while recording to cancel.
- **Prompt Mode** — hold **Right ⌘ Command** and ramble what you want an AI to do. It comes out as a properly engineered prompt (built from Anthropic's + OpenAI's official prompting guides).
- **Dictionary** — words spelled your way (also biases the speech engine itself, not just the cleanup).
- **Style** — a global voice plus per-context tone: it detects whether you're in Messages/WhatsApp (personal), Slack (work), Mail/Gmail (email), etc., and writes accordingly. All editable.
- **Insights** — words/day, time saved vs typing, streak, top apps.

Both hotkeys are changeable in Settings. Holding a hotkey and pressing any other key aborts, so normal shortcuts still work.

## Build & install

```sh
./scripts/build-app.sh --install        # ad-hoc signed → /Applications/Prompter.app
open /Applications/Prompter.app
```

First run: grant **Microphone** and **Accessibility** when prompted (Accessibility covers the hotkey listener, auto-paste, and window-title reading). If hotkeys don't respond after granting Accessibility, also grant **Input Monitoring** from Settings → Permissions.

**Keeping permissions across rebuilds:** ad-hoc signing means macOS sees every rebuilt binary as a new app, so grants reset after code changes. One-time fix: Keychain Access → Certificate Assistant → Create a Certificate → name `prompter-dev`, type **Code Signing** — then build with `./scripts/build-app.sh --identity prompter-dev --install`.

## Data (all local, all editable)

`~/Library/Application Support/Prompter/`

| File | What |
|---|---|
| `config.json` | settings |
| `dictionary.json` | your words |
| `styles.json` | voice + context styles |
| `history.jsonl` | insights log |
| `prompts/prompt-mode.md` | the Prompt Mode meta-prompt (edit freely) |
| `prompter.log` | app log |

## Headless testing

```sh
.build/release/Prompter --transcribe test.aiff      # speech engine only
.build/release/Prompter --test-llm                  # Claude backend health check
.build/release/Prompter --test-cleanup "um so hey can you er send me the the report"
.build/release/Prompter --test-prompt "I want like a blog post about contractor marketing, 500 words"
```
