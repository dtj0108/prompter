# Prompter

**Free, source-available voice-to-text and coding-prompt assistance for macOS.**

Prompter lets you talk instead of type in any Mac app. Hold a hotkey, speak, and release: your words are transcribed, optionally cleaned up, and inserted wherever your cursor is. A separate Prompt Mode turns rough spoken ideas into structured instructions for coding agents.

Prompter itself is completely free to download and use. There is no Prompter subscription, account, or telemetry service. The optional OpenRouter integration uses your own API key and may incur provider charges.

## Download

[**Download the latest Prompter release**](https://github.com/dtj0108/prompter/releases/latest/download/Prompter.zip)

Requirements:

- Apple Silicon Mac
- macOS 26 or newer
- Microphone and Accessibility permissions
- Optional: an [OpenRouter API key](https://openrouter.ai/keys) for Whisper transcription and AI cleanup

To install:

1. Unzip `Prompter.zip` and move `Prompter.app` to Applications.
2. Open Prompter. If macOS blocks the first launch, right-click the app, choose **Open**, then confirm.
3. Follow the Setup Assistant to grant Microphone and Accessibility access.
4. Add your OpenRouter key in **Settings → AI models** if you want cloud transcription.

After installation, Prompter can check for and install new releases from its Settings window.

## What it does

- **Dictation** — hold **Right ⌥ Option**, talk, and release to insert polished text at your cursor.
- **Hands-free dictation** — tap the dictation key once, speak for as long as you want, and tap it again to finish.
- **Coding Prompt Mode** — hold or tap **Right ⌘ Command** to turn a rough spoken request into a scoped, repository-aware coding prompt.
- **Dictionary** — teach Prompter names and specialized terms, including alternate “sounds like” spellings.
- **Snippets** — say a trigger such as “my email address” to insert reusable text.
- **App-aware style** — use different voices and formatting rules for Messages, Slack, email, AI tools, or your own app groups.
- **Insights** — see words dictated, estimated time saved, streaks, top apps, and reported OpenRouter cost.
- **Customizable hotkeys** — change both dictation and Prompt Mode keys in Settings.

Pressing another key while holding a Prompter hotkey cancels the recording, so normal keyboard shortcuts continue to work.

## How transcription works

With an OpenRouter key configured, Prompter records a temporary 16 kHz mono WAV and sends it to OpenRouter's Whisper Large V3 Turbo transcription endpoint. Apple's on-device SpeechAnalyzer runs as an automatic fallback. The temporary audio file is deleted after the request completes.

Without an OpenRouter key, transcription stays entirely on the Mac using Apple's speech engine. Optional text cleanup can use OpenRouter, a locally authenticated `claude` CLI, or plain dictionary corrections.

## Privacy and cost

- Prompter is free. You do not pay us to download, install, or use it.
- OpenRouter and other optional third-party services may charge for API usage under their own terms.
- Settings, dictionary entries, snippets, styles, and history are stored locally on your Mac.
- Audio is uploaded only when an OpenRouter key is configured; temporary recordings are deleted after transcription.
- Without an OpenRouter key, speech transcription remains on-device.

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
| `config.json` | Settings and the OpenRouter key, protected with mode `600` |
| `dictionary.json` | Custom words and pronunciations |
| `snippets.json` | Spoken triggers and expansions |
| `styles.json` | Voice and app-context rules |
| `history.jsonl` | Local insights history |
| `prompts/prompt-mode.md` | Editable Prompt Mode instructions |
| `prompter.log` | Diagnostic app log |

## Headless testing

```sh
.build/release/Prompter --transcribe test.aiff
.build/release/Prompter --transcribe-openrouter test.wav
.build/release/Prompter --test-llm
.build/release/Prompter --test-cleanup "um so hey can you send me the report"
.build/release/Prompter --test-prompt "build a 500-word contractor marketing post"
```

## Publishing updates

Pushes to `main` run `.github/workflows/publish-update.yml`. The workflow builds a versioned app, packages `Prompter.zip`, generates a SHA-256 update manifest, and publishes both in a GitHub Release. Installed copies check that public release feed and update only when the user chooses to install.

## License

Prompter is **free, source-available software** under the [Prompter Free Use License 1.0](LICENSE).

You may use it personally, at work, study it, modify it, and share original or modified copies for free. You may **not sell it, resell it, charge for access to it, or distribute it as part of a paid product**.

Because the license restricts resale, it is not an OSI-approved open-source license. The source is public so people can inspect, improve, and freely use the tool—not turn it into a product they charge others for.
