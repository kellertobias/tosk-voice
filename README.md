# ToskVoice

![ToskVoice screenshot](screenshot.png)

ToskVoice is a native, local-first macOS menu-bar dictation app for Apple Silicon Macs running macOS 26 or newer. It focuses on fast voice input, visible live feedback, local speech models, and privacy-preserving editor workflows.

## Quick Start

Build and install the current development version with Homebrew:

```sh
brew tap kellertobias/tosk-voice https://github.com/kellertobias/tosk-voice.git
brew trust --cask kellertobias/tosk-voice/tosk-voice
brew install --cask kellertobias/tosk-voice/tosk-voice
```

The cask downloads the `main` source snapshot and builds ToskVoice locally, so it does not require a GitHub release asset. Building requires Xcode with the macOS 26 SDK and network access for SwiftPM dependencies.

The development build is not notarized. If macOS blocks the first launch, try to open ToskVoice once, then go to **System Settings -> Privacy & Security** and choose **Open Anyway**. The first launch may also require granting Microphone and Accessibility permissions. After granting Accessibility, use **Restart ToskVoice** in the Privacy tab so macOS applies the change to the running app.

Shortcuts are configurable in Settings. The defaults are `Control-Option-Space` for toggle and `Control-Option-D` for push-to-talk.

## Features

- Nonactivating dictation overlay that keeps focus in the target application.
- Menu-bar waveform with click-to-toggle dictation and right-click settings.
- Live waveform, provisional text, and finalized text using Apple's on-device `SpeechAnalyzer`.
- English, German, and automatic bilingual profiles with custom vocabulary.
- Configurable global shortcuts, including toggle and push-to-talk modes.
- Focused-field insertion through Accessibility, with clipboard fallback when direct insertion is unavailable.
- Timestamped Markdown transcript output.
- Spoken correction handling, including natural phrases such as "strike that," "undo sentence," "replace X with Y," and German equivalents.
- Optional Apple Intelligence processing for live draft edits and polished final text.
- Local editable transcript history. Raw microphone audio is not retained.
- Selectable microphones and output devices.
- Optional WhisperKit, SpeakerKit, and Qwen3 TTS model packs with visible download/load state.
- Optional SpeakerKit diarization with time-aligned speaker labels.
- Text-to-speech from selected text or files using macOS voices, optional Qwen3 neural voices, and WAV/MP3 export.
- File-only Voice Editor with Apple Intelligence or an OpenAI-compatible endpoint, approved workspace roots, native diff review, atomic writes, and undo.
- Bundled Zed ACP agent and installable Obsidian companion.

All downloaded speech models run locally after installation. External editor providers are used only when explicitly selected and configured.

## Requirements

- Apple Silicon Mac.
- macOS 26 or newer.
- Microphone permission for recording.
- Accessibility permission for inserting dictated text and posting fallback paste events.

## Development

Local development builds require Xcode with the macOS 26 SDK.

Build and open the app from source:

```sh
./build open
```

Run tests:

```sh
./build test
```

Build the app bundle:

```sh
./build
```

Create a release archive:

```sh
./build archive
```

Install and open a release build locally:

```sh
./build archive install
```

`archive` creates an arm64 ZIP plus SHA-256 checksum in `artifacts/`. It includes the Zed ACP helper, Obsidian companion, and LAME encoder.

The build script prefers `/Applications/Xcode.app` when installed. If `TOSKVOICE_SIGNING_IDENTITY` is unset, it tries to use the first Apple Development or Developer ID Application signing identity. If none is available, it falls back to ad-hoc signing, which can cause macOS privacy grants to reset after rebuilds.

SwiftPM downloads pinned source dependencies automatically. The small arm64 LAME executable and license texts are vendored for reproducible MP3 export builds. The root `Brewfile` remains available for refreshing that tool.

## Voice Editor

Open **Voice Editor...** from the right-click menu, approve a workspace root, and choose either Apple Intelligence or an OpenAI-compatible API. Endpoint and model metadata stay in preferences; API keys are stored in macOS Keychain. A common local configuration is an Ollama-compatible `/v1` endpoint with no API key.

The native editor validates model-proposed relative paths against the approved root, rejects symlink escapes and stale file contents, defaults to preview-before-apply, and writes changes atomically. Auto-apply is an explicit per-workspace option.

## Zed and Obsidian

The Voice Editor window can copy the Zed `agent_servers` configuration for the bundled `toskvoice-agent`. The helper implements ACP protocol version 1, reads supported text files below Zed's project `cwd`, has no terminal tool, and reports file diffs back to Zed.

Use **Install Obsidian Companion...** to copy the plugin into a chosen vault. Its command sends the current note path and selection through the `toskvoice://edit` handoff. ToskVoice still requires the vault to be an approved workspace before it can change files.

## Homebrew

The cask lives at `Casks/tosk-voice.rb`. It downloads the `main` source snapshot from [kellertobias/tosk-voice](https://github.com/kellertobias/tosk-voice), builds the app locally with the repository's `./build archive` command, and installs the resulting app bundle. It does not depend on a published GitHub release.

Add this repository as a custom tap, trust the ToskVoice cask, and install it:

```sh
brew tap kellertobias/tosk-voice https://github.com/kellertobias/tosk-voice.git
brew trust --cask kellertobias/tosk-voice/tosk-voice
brew install --cask kellertobias/tosk-voice/tosk-voice
```

The `brew trust --cask` command authorizes only the ToskVoice cask from this non-official tap. It does not trust every cask or command in the repository.

The local build requires Xcode with the macOS 26 SDK and network access while SwiftPM downloads its pinned dependencies. To rebuild after changes land on `main`, run:

```sh
brew update
brew reinstall --cask kellertobias/tosk-voice/tosk-voice
```

Homebrew no longer supports `--no-quarantine`. Because the development build is not notarized, launch ToskVoice once and, if macOS blocks it, approve it under **System Settings -> Privacy & Security -> Open Anyway**.

A local archive can also be installed with `./build archive install`.

## Privacy

Speech recognition, diarization, Apple Intelligence corrections, and local TTS run on this Mac. ToskVoice stores preferences and transcript history in the user's Library. It does not retain raw audio.

Voice Editor workspace contents leave the Mac only when an external provider is selected. The UI identifies that provider before a request is sent.

## Project Status

ToskVoice is early-stage software. The repository is public for inspection and collaboration, but release signing, notarization, and packaged distribution are still being finalized.

## License

Copyright (c) 2026 Tobisk. All rights reserved until a project license is selected.
