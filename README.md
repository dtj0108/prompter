# Prompter

A personal replacement for Wispr Flow. Hold a key, talk, release — polished text appears wherever your cursor is. Or tap the key once and go hands-free.

Built as a native macOS Dock app. Speech-to-text runs **fully on-device** (Apple's macOS 26 `SpeechAnalyzer` — your audio never leaves the Mac). The AI cleanup runs through **OpenRouter** (add your `sk-or-…` key in Settings; the default is the small, fast `openai/gpt-5.6-luna` model), with automatic fallback to the `claude` CLI on your Claude subscription if no key is set, and plain dictionary-corrected transcripts if neither is available.

## What it does

- **Dictation** — hold **Right ⌥ Option**, talk, release. Prompter transcribes, cleans up filler/self-corrections, applies your dictionary and style, and pastes at your cursor. Esc cancels.
- **Hands-free** — *tap* the dictation key instead of holding: talk as long as you want (type, click around, doesn't matter), tap again to finish.
- **Coding Prompt Mode** — hold (or tap) **Right ⌘ Command** and ramble what you want a coding agent to do. It preserves your intent and turns the request into a scoped, repository-aware prompt with clear verification.
- **Dictionary** — words spelled your way (also biases the speech engine itself, not just the cleanup).
- **Snippets** — say "my email address" and the real thing gets typed. Whole-utterance triggers expand instantly with no AI round-trip; mid-sentence triggers are expanded by the cleanup pass.
- **Style** — a global voice plus app-aware tone: it detects Messages/WhatsApp (casual), Slack and Mail/Gmail (professional), and Codex/ChatGPT/Claude (structured for AI). The Style page shows your last active app so you can assign it to a context or create a custom rule in one click.
- **Insights** — words/day, time saved vs typing, streak, top apps, and actual AI spend in dollars (OpenRouter reports real cost per request).
- **Setup Assistant** — first launch walks through every permission; reopen any time from the menu bar.

Both hotkeys are changeable in Settings (applies immediately). Holding a hotkey and pressing any other key aborts, so normal shortcuts still work.

## Build & install

```sh
./scripts/build-app.sh --install        # ad-hoc signed → /Applications/Prompter.app
open /Applications/Prompter.app
```

First run: the Setup Assistant walks through **Microphone** and **Accessibility** (Accessibility covers the hotkey listener, auto-paste, and window-title reading). If hotkeys don't respond after granting Accessibility, also grant **Input Monitoring** from Settings → Permissions.

Also one-time: macOS 26 may show a "Prompter would like to paste from …" alert the first time it snapshots your clipboard (it saves and restores your clipboard around every insert) — choose **Always Allow**.

**AI backend:** paste an OpenRouter key in Settings → AI cleanup (get one at [openrouter.ai/keys](https://openrouter.ai/settings/keys)). Notes from research (July 2026): `:free` models are capped at 50 requests/day — 1,000/day after a one-time $10 credit top-up — and may train on your text; the default paid model is private and costs ~$0.03/day. If the chosen model errors, requests automatically fall back through `openai/gpt-oss-120b` → `qwen/qwen3-30b-a3b-instruct-2507` → `meta-llama/llama-3.3-70b-instruct`. No OpenRouter key? The `claude` CLI is used instead (one-time login: run `claude` in Terminal, then `/login`).

**Keeping permissions across rebuilds:** ad-hoc signing means macOS sees every rebuilt binary as a new app, so grants reset after code changes. One-time fix: Keychain Access → Certificate Assistant → Create a Certificate → name `prompter-dev`, type **Code Signing** — then build with `./scripts/build-app.sh --identity prompter-dev --install`.

## Data (all local, all editable)

`~/Library/Application Support/Prompter/`

| File | What |
|---|---|
| `config.json` | settings (incl. OpenRouter key — file is chmod 600) |
| `dictionary.json` | your words |
| `snippets.json` | trigger → expansion pairs |
| `styles.json` | voice + context styles |
| `history.jsonl` | insights log |
| `prompts/prompt-mode.md` | the Prompt Mode meta-prompt (edit freely) |

## Publishing updates

Pushes to `main` run `.github/workflows/publish-update.yml` on GitHub. The workflow builds a versioned app, packages `Prompter.zip`, writes an `update.json` manifest with its SHA-256, and publishes both as the latest GitHub Release. Prompter checks the public repository named by `PrompterUpdateRepository` in `Info.plist`; Settings shows the result and only downloads or installs when the user clicks the update button.

The source repository must be public (or the release assets must be mirrored publicly) because installed apps do not contain a GitHub access token. The build workflow injects its own `${{ github.repository }}` into release bundles automatically.
| `prompter.log` | app log |

## Headless testing

```sh
.build/release/Prompter --transcribe test.aiff      # speech engine only
.build/release/Prompter --test-llm                  # AI backend health check
.build/release/Prompter --test-cleanup "um so hey can you er send me the the report"
.build/release/Prompter --test-prompt "I want like a blog post about contractor marketing, 500 words"
```
