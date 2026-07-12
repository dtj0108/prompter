import AppKit

// Headless test modes (used for verification without the GUI):
//   Prompter --transcribe <audio-file>   → print transcript and exit
//   Prompter --test-llm                  → round-trip the Claude backend and exit
//   Prompter --test-cleanup "<text>"     → run the cleanup prompt on text and exit
//   Prompter --test-prompt "<text>"      → run Prompt Mode on text and exit
//   Prompter --test-context <bundle>     → print the matching style context and exit
//   Prompter --render-style <png-path>   → render the Style page for visual QA
if HeadlessCLI.runIfRequested() {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
