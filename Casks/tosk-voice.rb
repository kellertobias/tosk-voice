cask "tosk-voice" do
  version "0.1.0"
  sha256 :no_check

  url "https://github.com/kellertobias/tosk-voice/releases/download/v#{version}/ToskVoice-#{version}-macos-arm64.zip"
  name "ToskVoice"
  desc "Native, local-first dictation for modern Macs"
  homepage "https://github.com/kellertobias/tosk-voice"

  depends_on macos: :tahoe

  app "ToskVoice.app"

  caveats <<~EOS
    This early archive is not notarized. If macOS blocks the first launch,
    try to open ToskVoice once, then approve it under:
      System Settings -> Privacy & Security -> Open Anyway
  EOS
end
