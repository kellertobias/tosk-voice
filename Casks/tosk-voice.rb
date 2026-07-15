cask "tosk-voice" do
  version :latest
  sha256 :no_check

  url "https://github.com/kellertobias/tosk-voice/archive/refs/heads/main.tar.gz"
  name "ToskVoice"
  desc "Native, local-first dictation for modern Macs"
  homepage "https://github.com/kellertobias/tosk-voice"

  depends_on macos: :tahoe

  app "tosk-voice-main/.build/app/ToskVoice.app"

  preflight do
    source = staged_path/"tosk-voice-main"
    system_command "/bin/bash", args: [(source/"build").to_s, "archive"]
  end

  caveats <<~EOS
    ToskVoice was built locally from the main branch. Rebuilding requires Xcode
    with the macOS 26 SDK and network access for SwiftPM dependencies.

    This development build is not notarized. If macOS blocks the first launch,
    try to open ToskVoice once, then approve it under:
      System Settings -> Privacy & Security -> Open Anyway
  EOS
end
