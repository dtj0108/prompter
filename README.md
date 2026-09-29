# Prompter

**Free, source-available voice-to-text and coding-prompt assistance for macOS.**

Prompter lets you talk instead of type in any Mac app. Hold a hotkey, speak, and release: your words are transcribed, optionally cleaned up, and inserted wherever your cursor is. A separate Prompt Mode turns rough spoken ideas into structured instructions for coding agents.

Prompter itself is completely free to download and use. It requires a free Ambitious account, but there is no Prompter subscription or telemetry service. “Sign in with Ambitious” only confirms your identity: Prompter's tokens cannot read your feed, posts, messages, or other Ambitious content, and a saved sign-in keeps working when you're offline. GPT Live Transcribe requires your OpenAI API key and an internet connection. OpenRouter is optional for text cleanup and Prompt Mode.

## Download

[**Download the latest Prompter release**](https://github.com/dtj0108/prompter/releases/latest/download/Prompter.zip)

Requirements:

- Apple Silicon Mac
- macOS 26 or newer
- A free Ambitious account
- Microphone and Accessibility permissions
- An [OpenAI API key](https://platform.openai.com/settings/organization/api-keys) and internet connection for GPT Live Transcribe
- Optional: an [OpenRouter API key](https://openrouter.ai/keys) for fast AI cleanup and Prompt Mode

To install:

1. Unzip `Prompter.zip` and move `Prompter.app` to Applications.
2. Open Prompter. If macOS blocks the first launch, right-click the app, choose **Open**, then confirm.
3. Follow the Setup Assistant to sign in with Ambitious, then grant Microphone and Accessibility access.
4. On the **API keys** setup step, paste your OpenAI key and press **Test** — setup continues only once OpenAI confirms the key works. Add OpenRouter there too if you want AI cleanup or Prompt Mode. You can change either later in **Settings → API Keys**.

After installation, Prompter can check for and install new releases from its Settings window.

## What it does

- **Dictation** — hold **Right ⌥ Option**, talk, and release to insert polished text at your cursor.
- **Live typing (optional)** — enable **Settings → Behavior → Type live while I speak** to insert words as you talk. It defaults to off. Cleanup replaces only your dictation; moving the cursor, editing, or switching focus stops updates and copies the finished text. Unsupported fields use the usual paste when you finish. Escape keeps words already typed. Prompt Mode always inserts its finished rewrite.
- **Hands-free dictation** — tap the dictation key once, speak for as long as you want, and tap any dictation shortcut to finish.
- **Coding Prompt Mode** — hold or tap **Right ⌘ Command** to turn a rough spoken request into a scoped, repository-aware coding prompt.
- **Dictionary** — teach Prompter names and specialized terms, including alternate “sounds like” spellings.
- **Snippets** — say a trigger such as “my email address” to insert reusable text.
- **App-aware style** — use different voices and formatting rules for Messages, Slack, email, AI tools, or your own app groups.
- **Insights** — see words dictated, estimated time saved, streaks, top apps, and reported AI cost.
- **Multiple hotkeys** — in **Settings → Hotkeys**, click **Add shortcut…** under Dictation or Prompt Mode. Add keyboard shortcuts, middle-click, or auxiliary mouse buttons, and edit or remove individual shortcuts. Your existing shortcuts stay in place. Each mode keeps at least one shortcut, and duplicate assignments are rejected. Any shortcut for that mode can finish hands-free recording; held recordings finish when you release the shortcut you started with.

Pressing another key while holding a Prompter hotkey cancels the recording, so normal keyboard shortcuts continue to work. Primary and secondary mouse clicks are never treated as Prompter hotkeys.

## How transcription works

GPT Live Transcribe is the only speech model. Prompter converts microphone buffers to 24 kHz PCM and streams them directly to OpenAI while you speak. There is no Apple or OpenRouter speech fallback. If a connection fails, Prompter stops recording, preserves the GPT transcript received so far, and identifies the recovered result as partial. Audio that has not been transcribed cannot be recovered after a connection failure.

Live typing uses GPT's incremental transcript events with low latency, then reconciles the completed transcript and optional cleanup with the same text range. macOS Accessibility must expose readable text and an editable selection for this to work. Fields without those capabilities retain paste-at-the-end behavior. Live insertion never replaces the whole field or sends backspace sequences.

OpenRouter remains optional for cleanup and Prompt Mode; Gemini Flash Lite is the default. Without an OpenRouter key, cleanup can use a locally authenticated `claude` CLI or plain dictionary corrections.

## Privacy and cost

- Prompter is free. You do not pay us to download, install, or use it.
- A free Ambitious account is required. Account identity and tokens are kept in the Mac Keychain, never in `config.json` or `prompter.log`.
- Ambitious sign-in is identity-only. It cannot read or post Ambitious content, and cached identity keeps dictation available through network or Ambitious outages.
- OpenAI, OpenRouter, and other optional third-party services may charge for API usage under their own terms.
- Settings, dictionary entries, snippets, styles, and history are stored locally on your Mac.
- Dictation audio streams to OpenAI using your configured key. Live typing changes when text appears, not whether OpenAI receives audio.
- OpenRouter receives text only for cleanup and Prompt Mode. Microphone audio is no longer saved to a temporary WAV.

## Build from source

```sh
git clone https://github.com/dtj0108/prompter.git
cd prompter
./scripts/build-app.sh --install
open /Applications/Prompter.app
```

Ad-hoc signing can cause macOS to request permissions again after each rebuild. For a stable local identity, create a Code Signing certificate named `prompter-dev`, then build with:

```sh
./scripts/build-app.sh --identity prompter-dev --install
```

## Local data

Prompter stores editable state in `~/Library/Application Support/Prompter/`:

| File | Contents |
|---|---|
| `config.json` | Settings plus OpenAI/OpenRouter keys, protected with mode `600` |
| `dictionary.json` | Custom words and pronunciations |
| `snippets.json` | Spoken triggers and expansions |
| `styles.json` | Voice and app-context rules |
| `history.jsonl` | Local insights history |
| `prompts/prompt-mode.md` | Editable Prompt Mode instructions |
| `prompter.log` | Diagnostic app log |

Ambitious identity and OAuth tokens are stored separately in the macOS Keychain under service `com.drew.prompter.ambitious`; they are never written to these files.

## Headless testing

The `--transcribe` and `--transcribe-openai` commands require a cached Ambitious sign-in, just like GUI dictation. Developer diagnostics beginning with `--test-` stay available without an account.

```sh
.build/release/Prompter --transcribe test.aiff
.build/release/Prompter --transcribe-openai test.aiff
.build/release/Prompter --test-stream-openai test.aiff  # paced live-stream diagnostic
.build/release/Prompter --test-llm
.build/release/Prompter --test-cleanup "um so hey can you send me the report"
.build/release/Prompter --test-prompt "build a 500-word contractor marketing post"
```

## Contributing

Contributions are welcome through pull requests. The `main` branch is protected and does not accept direct pushes.

1. Fork this repository.
2. Create a focused branch in your fork.
3. Make and test your changes.
4. Open a pull request against `dtj0108/prompter:main` with a clear explanation of what changed and why.

Every pull request requires review and approval from the repository owner before it can be merged. Reviews may request changes, and approval can be dismissed when new commits materially change the proposed work. Please keep pull requests focused and do not include unrelated formatting or refactoring.

## Publishing updates

Pushes to `main` run `.github/workflows/publish-update.yml`. The workflow builds a versioned app, signs it with a stable Developer ID identity, notarizes and staples it, packages `Prompter.zip`, generates a SHA-256 update manifest, and publishes both in a GitHub Release. Installed copies check that public release feed and update only when the user chooses to install.

The release workflow requires these GitHub Actions secrets:

- `MACOS_CERTIFICATE` — base64-encoded Developer ID Application `.p12`
- `MACOS_CERTIFICATE_PASSWORD` — password used when exporting the `.p12`
- `MACOS_PROVISIONING_PROFILE` — base64-encoded Developer ID provisioning profile for `com.drew.prompter`, including Associated Domains and the same Developer ID certificate
- `APPLE_API_KEY` — contents of the App Store Connect team API private key (`.p8`)
- `APPLE_API_KEY_ID` — App Store Connect team API key ID
- `APPLE_API_ISSUER` — App Store Connect API issuer ID

Keep the signing certificate and bundle identifier stable across releases. Changing either one causes macOS to treat the update as a different app and request permissions again. Renew and replace `MACOS_PROVISIONING_PROFILE` before its expiration; the release workflow rejects expired profiles and profiles that do not contain the imported signing certificate.

## License

Prompter is **free, source-available software** under the [Prompter Free Use License 1.0](LICENSE).

You may use it personally, at work, study it, modify it, and share original or modified copies for free. You may **not sell it, resell it, charge for access to it, or distribute it as part of a paid product**.

Because the license restricts resale, it is not an OSI-approved open-source license. The source is public so people can inspect, improve, and freely use the tool—not turn it into a product they charge others for.
