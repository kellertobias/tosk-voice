# ToskVoice

ToskVoice is a native, local-first macOS menu-bar dictation app for Apple Silicon Macs running macOS 26 or newer.

## What works

- A nonactivating overlay that never steals focus from the target application.
- A reactive menu-bar waveform while listening. Normal click toggles dictation; right-click opens the app menu.
- Live waveform, provisional text, and finalized text using Apple's on-device `SpeechAnalyzer`.
- English and German profiles with contextual vocabulary.
- Toggle dictation with `Control–Option–Space` or hold `Control–Option–D` for push-to-talk.
- Insert once when dictation stops, using Accessibility first and a clipboard-preserving paste fallback.
- Append timestamped blocks to a configured Markdown file.
- Spoken correction commands: “strike that,” “undo sentence,” “replace X with Y,” and “undo correction,” including German equivalents.
- Semantic corrections using the Apple Intelligence on-device model when available.
- Local editable transcript history; raw microphone audio is not retained.
- Selectable microphones and output devices from the menu and Settings.
- Automatic bilingual WhisperKit mode with an opt-in model download.
- Optional SpeakerKit diarization with time-aligned “Speaker 1,” “Speaker 2,” … labels. Session audio exists only in memory and is discarded after labeling.
- Text-to-speech from selected text or files using macOS voices, optional Qwen3 neural voices, and WAV/MP3 export.
- A file-only Voice Editor with Apple Intelligence or any OpenAI-compatible endpoint (including Ollama), approved workspace roots, native diff review, atomic writes, and undo.
- A bundled Zed ACP agent and installable Obsidian companion.

All downloaded speech models run locally after installation. External editor providers are used only when you explicitly select and configure one.

## Build and run

```sh
./build open
```

ToskVoice uses three separate macOS permissions: Microphone for audio, Input Monitoring for global shortcuts, and Accessibility for inserting text into another application. Their live status and request buttons are available under **Settings → Privacy**. After granting Input Monitoring or Accessibility, quit and reopen ToskVoice so macOS applies the change.

Development builds are ad-hoc signed unless `TOSKVOICE_SIGNING_IDENTITY` names an existing Apple Development or Developer ID identity. Apple ties privacy grants for ad-hoc apps to the exact build, so a changed development binary may need to be enabled again. Starting dictation never requests Accessibility automatically; use **Settings → Privacy → Request Access** when needed.

Shortcuts are configurable in Settings. The defaults are `Control–Option–Space` for toggle and `Control–Option–D` for push-to-talk.

Other commands:

```sh
./build test
./build archive
./build archive install
```

`archive` creates an ad-hoc-signed arm64 ZIP plus SHA-256 checksum in `artifacts/`. It includes the Zed ACP helper, Obsidian companion, and LAME encoder. `archive install` also installs and opens `/Applications/ToskVoice.app`.

The script prefers `/Applications/Xcode.app` when installed. App builds require a macOS 26 SDK. SwiftPM downloads pinned source dependencies automatically, while the small arm64 LAME executable and its license texts are vendored for reproducible MP3 builds. The root `Brewfile` remains available for refreshing that tool. Tests require the XCTest support included with full Xcode on systems whose standalone Command Line Tools omit it.

## Voice Editor providers

Open **Voice Editor…** from the right-click menu, approve a workspace root, and choose either Apple Intelligence or an OpenAI-compatible API. Endpoint and model metadata stay in preferences; API keys are stored in macOS Keychain. A common local configuration is an Ollama-compatible `/v1` endpoint with no API key.

The native editor always validates model-proposed relative paths against the approved root, rejects symlink escapes and stale file contents, and defaults to preview-before-apply. Auto-apply is an explicit per-workspace option.

## Zed and Obsidian

The Voice Editor window can copy the Zed `agent_servers` configuration for the bundled `toskvoice-agent`. The helper implements ACP protocol version 1, reads only supported text files below Zed's project `cwd`, has no terminal tool, and reports file diffs back to Zed.

Use **Install Obsidian Companion…** to copy the small plugin into a chosen vault. Its command sends the current note path and selection through the `toskvoice://edit` handoff; ToskVoice still requires the vault to be an approved workspace before it can change files.

## Homebrew

The cask template lives at `Packaging/homebrew/tosk-voice.rb` and targets `kellertobias/homebrew-tap`. Before notarization, releases require Homebrew's `--no-quarantine` option as documented by the cask. A local archive can also be installed with `./build archive install`.

## Privacy

Speech recognition, diarization, Apple Intelligence corrections, and local TTS run on this Mac. ToskVoice stores preferences and transcript history in the user's Library. It does not retain raw audio. Voice Editor workspace contents leave the Mac only when an external provider is selected; the UI identifies that provider before a request is sent.

## License

Copyright © 2026 Tobisk. All rights reserved until a project license is selected.
