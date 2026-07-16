import Foundation
import ArgmaxCore
import SpeakerKit
import TTSKit
import WhisperKit

@MainActor
final class ModelPackController: ObservableObject {
    enum PackState: Equatable {
        case notInstalled
        case downloading(Double?)
        case loading
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .notInstalled: "Not installed"
            case .downloading(let progress):
                if let progress {
                    "Downloading \(Int(progress * 100))%"
                } else {
                    "Downloading..."
                }
            case .loading: "Loading…"
            case .ready: "Ready"
            case .failed: "Failed"
            }
        }

        var progressValue: Double? {
            guard case .downloading(let progress) = self else { return nil }
            return progress
        }

        var isActive: Bool {
            switch self {
            case .downloading, .loading:
                true
            case .notInstalled, .ready, .failed:
                false
            }
        }

        var errorMessage: String? {
            if case .failed(let message) = self { message } else { nil }
        }

        var isFailed: Bool {
            errorMessage != nil
        }

        var isReady: Bool {
            self == .ready
        }

        private static func clamped(_ progress: Double) -> Double {
            min(max(progress, 0), 1)
        }

        static func downloadProgress(_ progress: Progress) -> PackState {
            let fraction = progress.fractionCompleted
            if fraction.isFinite {
                return .downloading(clamped(fraction))
            }
            return .downloading(nil)
        }
    }

    @Published private(set) var whisperState: PackState = .notInstalled
    @Published private(set) var speakerState: PackState = .notInstalled
    @Published private(set) var neuralVoiceState: PackState = .notInstalled

    private(set) var whisperKit: WhisperKit?
    private(set) var speakerKit: SpeakerKit?
    private(set) var ttsKit: TTSKit?

    func prepareWhisper() async throws -> WhisperKit {
        if let whisperKit { return whisperKit }
        let model = "large-v3-v20240930_626MB"
        whisperState = .downloading(nil)
        do {
            let modelFolder = try await WhisperKit.download(
                variant: model,
                useBackgroundSession: true
            ) { [weak self] progress in
                Task<Void, Never> { @MainActor in
                    self?.whisperState = .downloadProgress(progress)
                }
            }
            whisperState = .loading
            let config = WhisperKitConfig(
                model: model,
                modelFolder: modelFolder.path,
                verbose: false,
                prewarm: true,
                load: true,
                download: false,
                useBackgroundDownloadSession: true
            )
            let kit = try await WhisperKit(config)
            whisperKit = kit
            whisperState = .ready
            return kit
        } catch {
            whisperState = .failed(error.localizedDescription)
            throw error
        }
    }

    func prepareSpeakerKit() async throws -> SpeakerKit {
        if let speakerKit { return speakerKit }
        removeRepoIfPartiallyDownloaded("argmaxinc/speakerkit-coreml")
        speakerState = .downloading(nil)
        do {
            // download must stay enabled: the flag gates ALL model resolution
            // in SpeakerKit, including the explicit downloadModels() below —
            // with false it throws "download is disabled" on first install.
            let config = PyannoteConfig(download: true, load: false)
            let kit = try await SpeakerKit(config)
            if let diarizer = kit.diarizer as? SpeakerKitDiarizer {
                let modelManager = diarizer as ModelManager
                try await modelManager.downloadModels { [weak self] progress in
                    Task<Void, Never> { @MainActor in
                        self?.speakerState = .downloadProgress(progress)
                    }
                }
                speakerState = .loading
                try await modelManager.loadModels()
            } else {
                speakerState = .loading
                try await kit.ensureModelsLoaded()
            }
            speakerKit = kit
            speakerState = .ready
            return kit
        } catch {
            speakerState = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Removes a model repo whose previous download was interrupted (the app
    /// quit mid-fetch). Leftover .incomplete markers mean partial files that
    /// the downloader's local-presence check would wrongly accept, making
    /// Core ML fail later with missing-weights errors.
    private func removeRepoIfPartiallyDownloaded(_ repoPath: String) {
        let repo = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/models/\(repoPath)", isDirectory: true)
        guard let files = FileManager.default.enumerator(at: repo, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in files where file.lastPathComponent.hasSuffix(".incomplete") {
            try? FileManager.default.removeItem(at: repo)
            return
        }
    }

    func prepareNeuralVoice() async throws -> TTSKit {
        if let ttsKit { return ttsKit }
        removeRepoIfPartiallyDownloaded("argmaxinc/ttskit-coreml")
        neuralVoiceState = .downloading(nil)
        do {
            let config = TTSKitConfig(
                model: .qwen3TTS_0_6b,
                verbose: false,
                useBackgroundDownloadSession: true,
                download: false,
                prewarm: true,
                load: true
            )
            let modelFolder = try await TTSKit.download(config: config) { [weak self] progress in
                Task<Void, Never> { @MainActor in
                    self?.neuralVoiceState = .downloadProgress(progress)
                }
            }
            config.modelFolder = modelFolder
            neuralVoiceState = .loading
            let kit = try await TTSKit(config)
            ttsKit = kit
            neuralVoiceState = .ready
            return kit
        } catch {
            neuralVoiceState = .failed(error.localizedDescription)
            throw error
        }
    }
}
