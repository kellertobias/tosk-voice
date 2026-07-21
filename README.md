# ToskVoice

![ToskVoice screenshot](screenshot.png)

ToskVoice is a native, local-first macOS menu-bar dictation app for Apple Silicon Macs running macOS 26 or newer. It focuses on fast voice input, visible live feedback, local speech models, and privacy-preserving editor workflows.

## Quick Start

Requirements:

- Apple Silicon Mac running macOS 26 or newer.
- Xcode with the macOS 26 SDK.
- Network access while Homebrew downloads the source and SwiftPM dependencies.

Build and install ToskVoice with Homebrew:

```sh
brew tap kellertobias/tosk-voice https://github.com/kellertobias/tosk-voice.git
brew trust --cask kellertobias/tosk-voice/tosk-voice
brew install --cask kellertobias/tosk-voice/tosk-voice
```

The cask downloads the `main` source snapshot and builds ToskVoice locally, so it does not require a GitHub release asset.

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
- Local editable transcript history with configurable retention, from 15 minutes to 3 months or off. Raw microphone audio is not retained.
- Selectable microphones and output devices.
- Optional WhisperKit, SpeakerKit, and Qwen3 TTS model packs with visible download/load state.
- Optional SpeakerKit diarization with time-aligned speaker labels.
- Text-to-speech from selected text or files using macOS voices, optional Qwen3 neural voices, and WAV/MP3 export.
- Edit with Voice window: an expandable dictation editor with cursor-following dictation, push-to-talk, spoken corrections, file editing, and an "Improve Result" cleanup pass via Apple Intelligence or an OpenAI-compatible endpoint.
- Bundled Zed ACP agent.

All downloaded speech models run locally after installation. External editor providers are used only when explicitly selected and configured.

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

`archive` creates an arm64 ZIP plus SHA-256 checksum in `artifacts/`. It includes the Zed ACP helper and LAME encoder.

The build script prefers `/Applications/Xcode.app` when installed. If `TOSKVOICE_SIGNING_IDENTITY` is unset, it tries to use the first Apple Development or Developer ID Application signing identity. If none is available, it falls back to ad-hoc signing, which can cause macOS privacy grants to reset after rebuilds.

SwiftPM downloads pinned source dependencies automatically. The small arm64 LAME executable and license texts are vendored for reproducible MP3 export builds. The root `Brewfile` remains available for refreshing that tool.

## Releases

Releases are automated with [Conventional Commits](https://www.conventionalcommits.org/). The `type:` prefix of each commit on `main` decides the version bump:

| Commit type | Release |
| --- | --- |
| `fix:`, `perf:` | patch (`x.y.Z`) |
| `feat:` | minor (`x.Y.z`) |
| `!` after the type/scope, or a `BREAKING CHANGE:` footer | major (`X.y.z`) |
| `docs:`, `refactor:`, `test:`, `style:`, `build:`, `ci:`, `chore:` | none |

The pipeline is split across two hosts, because [git.tokenet.de](https://git.tokenet.de/opensource/tosk-voice) is the authoritative CI and GitHub is a push mirror:

- **Forgejo** (`.forgejo/workflows/release.yml`) runs on every push to `main`. [`semantic-release`](https://semantic-release.gitbook.io/) analyses the commits, writes the new version to `VERSION`, updates `CHANGELOG.md`, commits `chore(release): vX.Y.Z [skip ci]`, and pushes the `vX.Y.Z` tag. `VERSION` is the single authoritative version source; `./build` reads it and stamps `CFBundleShortVersionString`.
- **GitHub** (`.github/workflows/release.yml`) reacts to the mirrored `v*` tag: it builds the app on a `macos-26` runner via `./build archive` and publishes a GitHub release with the arm64 ZIP and its `.sha256`. The build is **not** signed or notarized (no Apple Developer account) — it uses an ad-hoc signature, so macOS warns on first launch. Only the `v*` tag builds and publishes; you can also trigger the workflow manually from the Actions tab to rebuild a tag or test-build a branch without publishing.

The first release-worthy commit produces `v1.0.0`.

Requirements:

- Forgejo secret `SEMANTIC_RELEASE_TOKEN` with repository write access, so the release job can push the release commit and tag past branch protection.
- The Forgejo → GitHub push mirror must forward tags (it does by default) so the `v*` tag reaches GitHub.

Preview the next version and notes without releasing:

```sh
npm ci
npm run release:dry
```

## Edit with Voice

Open **Edit with Voice...** from the right-click menu (or expand a running dictation from the overlay) to work on a transcript or any text file in a regular window: dictation follows the cursor, selections can be spoken over, and **Improve Result** removes filler words and stutters using Apple Intelligence or a configurable OpenAI-compatible endpoint (Ollama, mlx, OpenAI) set in Settings → General.

## Zed

The bundled `toskvoice-agent` helper implements ACP protocol version 1, reads supported text files below Zed's project `cwd`, has no terminal tool, and reports file diffs back to Zed.

It uses Apple Intelligence by default. To run it against an OpenAI-compatible endpoint instead, set `TOSKVOICE_MODEL` — and, as needed, `TOSKVOICE_BASE_URL` (default `http://localhost:11434/v1`) and `TOSKVOICE_API_KEY` — in the `agent_servers` entry for `toskvoice-agent` in Zed's settings.

## Homebrew

The cask lives at `Casks/tosk-voice.rb`. It downloads the `main` source snapshot from [kellertobias/tosk-voice](https://github.com/kellertobias/tosk-voice), builds the app locally with the repository's `./build archive` command, and installs the resulting app bundle. It does not depend on a published GitHub release.

The complete installation and requirements are in [Quick Start](#quick-start). Its `brew trust --cask` command authorizes only the ToskVoice cask from this non-official tap; it does not trust every cask or command in the repository.

The local build requires Xcode with the macOS 26 SDK and network access while SwiftPM downloads its pinned dependencies. To update or reinstall ToskVoice, run:

```sh
brew update
brew reinstall --cask kellertobias/tosk-voice/tosk-voice
```

Homebrew no longer supports `--no-quarantine`. Because the development build is not notarized, launch ToskVoice once and, if macOS blocks it, approve it under **System Settings -> Privacy & Security -> Open Anyway**.

A local archive can also be installed with `./build archive install`.

## Privacy

Speech recognition, diarization, Apple Intelligence corrections, and local TTS run on this Mac. ToskVoice stores preferences and transcript history in the user's Library. It does not retain raw audio. Transcript history is pruned automatically on the retention interval set in Settings → General, which defaults to 24 hours.

Text leaves the Mac only when an external provider is explicitly selected (for example for "Improve Result"). The settings identify that provider before a request is sent.

## Project Status

ToskVoice is early-stage software. The repository is public for inspection and collaboration, but release signing, notarization, and packaged distribution are still being finalized.

## License

Copyright (c) 2026 Tobisk. All rights reserved until a project license is selected.
