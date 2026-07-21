## [1.0.1](https://git.tokenet.de/opensource/tosk-voice/compare/v1.0.0...v1.0.1) (2026-07-21)


### Bug Fixes

* publish GitHub release by removing [skip ci] from release commit ([036cec6](https://git.tokenet.de/opensource/tosk-voice/commit/036cec67c5229937945177b0b667a11ab5631d1e))
* trigger the mirrored release build ([8ed06a0](https://git.tokenet.de/opensource/tosk-voice/commit/8ed06a04a3efbddfec50e23703abe96aaf7695ac))

# 1.0.0 (2026-07-21)


### Bug Fixes

* clear the waveform when the dictation overlay reopens ([3621725](https://git.tokenet.de/opensource/tosk-voice/commit/3621725e349ac87433f9e31f6dee5530bf4c739c))
* deliver dictation into Electron apps and terminals ([4d8459f](https://git.tokenet.de/opensource/tosk-voice/commit/4d8459f6cb28f194a51a3670c9a537aa18b85de3))
* enable SpeakerKit model download on first install ([a7e7a0b](https://git.tokenet.de/opensource/tosk-voice/commit/a7e7a0b787e24dfe4f7949ca608c6bbd038b7001))
* fish-speech install — lockfile sync, portaudio, gated-model guidance ([31f4f2d](https://git.tokenet.de/opensource/tosk-voice/commit/31f4f2d6fe2c4e72b470eaa4cb05acd8d048f6a6))
* improve focused text replacement ([2f386c8](https://git.tokenet.de/opensource/tosk-voice/commit/2f386c8cf81b3d52d0b3a172be65a89f17d258c9))
* install Python 3.13 for Fish-Speech uv sync ([565c2fb](https://git.tokenet.de/opensource/tosk-voice/commit/565c2fb3bd91c21d2d49de645c0aac9a6268a5ad))
* keep the system tap IO block off the main actor ([f295763](https://git.tokenet.de/opensource/tosk-voice/commit/f295763aabe3a5fd69b0594744f721ef439669ac))
* make Fish-Speech install idempotent on existing venv ([ea5b013](https://git.tokenet.de/opensource/tosk-voice/commit/ea5b013d19cfb8af8569c0b835f131e63728aef7))
* post paste sequence the way proven tools do ([ea1d97e](https://git.tokenet.de/opensource/tosk-voice/commit/ea1d97e23a45fc68e6a8686541ed5b2895cb6843))
* self-heal partially downloaded model packs ([a8fbd96](https://git.tokenet.de/opensource/tosk-voice/commit/a8fbd96c5b0b2d1184513d078f849f2502abba10))
* surface missing Accessibility permission and harden focused-field insertion ([b9e83b3](https://git.tokenet.de/opensource/tosk-voice/commit/b9e83b30bb09b16f3d68d03f11fd9012ed9ded05))
* tap helper processes so Chrome/Teams audio is captured ([b140c13](https://git.tokenet.de/opensource/tosk-voice/commit/b140c13b048a89e2f2ec6516b0699e53094bcf14))
* target the captured field when pasting, not whatever has focus ([82e15a2](https://git.tokenet.de/opensource/tosk-voice/commit/82e15a266b69f4da335e486b1b36c32d42ec158d))


### Features

* add editor integrations ([7f9acbc](https://git.tokenet.de/opensource/tosk-voice/commit/7f9acbca6b8988d4ad89788be0c4f7785b46f8d4))
* add live correction processing ([b004d96](https://git.tokenet.de/opensource/tosk-voice/commit/b004d969319f0e5e0e21d6e606e111dc533883cb))
* add native dictation app ([0c6d975](https://git.tokenet.de/opensource/tosk-voice/commit/0c6d9756fbc0ec4f4936b490f2c9c67e5278223c))
* ask whether to reset or extend an existing transcript on Start ([bbd14d9](https://git.tokenet.de/opensource/tosk-voice/commit/bbd14d988c84cb95761202fd9614127911e267cb))
* clear the Edit with Voice document when the window closes ([70301bd](https://git.tokenet.de/opensource/tosk-voice/commit/70301bd347cad5cc492b920fe3819135eb3c8d81))
* copy button on every status and error message ([5155d3a](https://git.tokenet.de/opensource/tosk-voice/commit/5155d3a8b7243cc888b8fb6463d5ea6c3d9d2cc0))
* Edit with Voice window replacing the file-only Voice Editor ([31d76bb](https://git.tokenet.de/opensource/tosk-voice/commit/31d76bb96589fe49e4d5e46d3eb741b2ce6f2b72))
* Fish-Speech native API style for the TTS server engine ([6a89909](https://git.tokenet.de/opensource/tosk-voice/commit/6a89909f8ab6761c0aa63d8c98ea825d97f1d72d))
* guided in-app Fish-Speech setup with Hugging Face token field ([a368103](https://git.tokenet.de/opensource/tosk-voice/commit/a3681030e962cdbc2186cf86ec055d045df2ad3d))
* hidden main menu — clipboard shortcuts and window-close keys ([04084e7](https://git.tokenet.de/opensource/tosk-voice/commit/04084e7f50d2544cc9491646189a1b9fd9ac3425))
* improve settings and model controls ([8b571c2](https://git.tokenet.de/opensource/tosk-voice/commit/8b571c2fd932167f2c06eb892772b0caa8bc382a))
* managed TTS server mode ([08f8107](https://git.tokenet.de/opensource/tosk-voice/commit/08f81076bfe41c704e70667078c33daba16e1245))
* meeting transcript mode with system audio process tap ([4c83a6c](https://git.tokenet.de/opensource/tosk-voice/commit/4c83a6c0e83e956b5254a13c9f7d6f4cee9afcff))
* meeting window pause, save, close prompt, Q&A column, timeline rail ([5cd61b5](https://git.tokenet.de/opensource/tosk-voice/commit/5cd61b577f4881023bfeadde6734a329fc64511c))
* menu reorder and system-wide TTS text service ([cd0c705](https://git.tokenet.de/opensource/tosk-voice/commit/cd0c7055b89fe20d35b63fea1dc08e2e9f6555dc))
* microphone mute in the meeting transcript window ([987eb87](https://git.tokenet.de/opensource/tosk-voice/commit/987eb878a003673fb5acae1d552070447533b6b1))
* microphone picker in the meeting transcript window ([f712bfa](https://git.tokenet.de/opensource/tosk-voice/commit/f712bfaa484ca6d11eecb1c54c6824cc4b6628b1))
* one-click TTS server setup and launch auto-start ([8929b35](https://git.tokenet.de/opensource/tosk-voice/commit/8929b359146e618527257d6c40b27cc16635297d))
* OpenAI-compatible TTS server engine (XTTS v2, Fish-Speech, …) ([1e5b1af](https://git.tokenet.de/opensource/tosk-voice/commit/1e5b1aff2053cd2b7bbea0d3bcc89f1ef566b426))
* refocus the captured field on delivery and stay there ([cc6210a](https://git.tokenet.de/opensource/tosk-voice/commit/cc6210a26c842211372b4a4e0da85e52d470330f))
* reorder overlay controls with a dedicated copy button ([641391c](https://git.tokenet.de/opensource/tosk-voice/commit/641391ce0351514be8b209837cd201fd9df47736))
* segment removal and App Switcher presence for document windows ([10dcb81](https://git.tokenet.de/opensource/tosk-voice/commit/10dcb810d506eca16088921c1d5a5e61d2bfecb2))
* speaker detection for the remote lane ([a976ffa](https://git.tokenet.de/opensource/tosk-voice/commit/a976ffa72850885f81e1422b7dce130986c028ab))
* two-click confirmation for segment removal ([9fbf40f](https://git.tokenet.de/opensource/tosk-voice/commit/9fbf40f2870a5d1c356bc3540b4622be0544e19d))

# Changelog

All notable changes are recorded here. Entries are generated automatically from
[Conventional Commits](https://www.conventionalcommits.org/) by the Forgejo release
pipeline; do not edit this file by hand.
