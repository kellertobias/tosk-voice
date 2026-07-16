import Foundation

/// One-click server presets: what to install, how to launch it, and the
/// matching ToskVoice server configuration.
enum TTSServerPreset: String, CaseIterable, Identifiable {
    case fishSpeech
    case xtts

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fishSpeech: "Fish-Speech"
        case .xtts: "XTTS v2"
        }
    }

    var summary: String {
        switch self {
        case .fishSpeech:
            "Clones fish-speech into ~/src, installs it with uv (installed via Homebrew if missing), and downloads the openaudio-s1-mini model (~2 GB). Runs on the Mac GPU in FP16."
        case .xtts:
            "Clones openedai-speech into ~/src and installs it into a Python 3.11 venv. Note: XTTS is CPU-only on Apple Silicon and noticeably slow; it shines when the server runs on a CUDA machine instead."
        }
    }

    var installScript: String {
        switch self {
        case .fishSpeech:
            """
            set -euo pipefail
            command -v uv >/dev/null 2>&1 || brew install uv
            mkdir -p "$HOME/src"
            [ -d "$HOME/src/fish-speech" ] || git clone https://github.com/fishaudio/fish-speech "$HOME/src/fish-speech"
            cd "$HOME/src/fish-speech"
            [ -d .venv ] || uv venv --python 3.12
            uv pip install -e .
            uv pip install 'huggingface_hub[cli]'
            uv run huggingface-cli download fishaudio/openaudio-s1-mini --local-dir checkpoints/openaudio-s1-mini
            echo "SETUP-COMPLETE"
            """
        case .xtts:
            """
            set -euo pipefail
            command -v python3.11 >/dev/null 2>&1 || brew install python@3.11
            mkdir -p "$HOME/src"
            [ -d "$HOME/src/openedai-speech" ] || git clone https://github.com/matatonic/openedai-speech "$HOME/src/openedai-speech"
            cd "$HOME/src/openedai-speech"
            [ -d venv ] || python3.11 -m venv venv
            ./venv/bin/pip install -r requirements.txt
            echo "SETUP-COMPLETE"
            """
        }
    }

    /// Configuration applied on successful setup; the API key is preserved
    /// from the existing configuration by the caller.
    func configuration(autoStart: Bool) -> TTSServerConfiguration {
        var config = TTSServerConfiguration()
        config.autoStart = autoStart
        config.mode = .local
        switch self {
        case .fishSpeech:
            config.engine = .fish
            config.apiStyle = .fishSpeech
            config.baseURL = "http://127.0.0.1:8080"
            config.model = ""
            config.managedCommand = #"cd "$HOME/src/fish-speech" && uv run tools/api_server.py --listen 127.0.0.1:8080 --llama-checkpoint-path checkpoints/openaudio-s1-mini --decoder-checkpoint-path checkpoints/openaudio-s1-mini/codec.pth --decoder-config-name modded_dac_vq --half"#
        case .xtts:
            config.engine = .xtts
            config.apiStyle = .openAI
            config.baseURL = "http://127.0.0.1:8000"
            config.model = "tts-1-hd"
            config.managedCommand = #"cd "$HOME/src/openedai-speech" && ./venv/bin/python speech.py --port 8000"#
        }
        return config
    }
}

/// Runs a preset's install script through a login shell, streaming output
/// for display. Long-running (git clones, pip installs, model downloads).
@MainActor
final class TTSServerInstaller: ObservableObject {
    enum State: Equatable {
        case idle
        case running(TTSServerPreset)
        case succeeded(TTSServerPreset)
        case failed(String)

        var label: String {
            switch self {
            case .idle: ""
            case .running(let preset): "Installing \(preset.label)…"
            case .succeeded(let preset): "\(preset.label) is set up"
            case .failed(let message): "Setup failed: \(message)"
            }
        }

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var recentOutput: [String] = []

    private var process: Process?

    /// Starts the installation; `onSuccess` runs on completion so the caller
    /// can apply the preset's configuration.
    func install(_ preset: TTSServerPreset, onSuccess: @escaping @MainActor () -> Void) {
        guard !state.isRunning else { return }
        recentOutput = []
        state = .running(preset)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", preset.installScript]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.split(separator: "\n").map(String.init)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recentOutput.append(contentsOf: lines)
                if self.recentOutput.count > 40 { self.recentOutput.removeFirst(self.recentOutput.count - 40) }
            }
        }
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.process === finished else { return }
                self.process = nil
                if finished.terminationStatus == 0 {
                    self.state = .succeeded(preset)
                    onSuccess()
                } else {
                    let hint = self.recentOutput.suffix(3).joined(separator: " · ")
                    self.state = .failed(hint.isEmpty ? "exit status \(finished.terminationStatus)" : hint)
                }
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        guard let process else { return }
        self.process = nil
        let sweeper = Process()
        sweeper.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        sweeper.arguments = ["-TERM", "-P", String(process.processIdentifier)]
        try? sweeper.run()
        process.terminate()
        state = .idle
    }
}
