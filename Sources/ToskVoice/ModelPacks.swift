import Foundation
import SpeakerKit
import TTSKit
import WhisperKit

@MainActor
final class ModelPackController: ObservableObject {
    enum PackState: Equatable {
        case notInstalled
        case downloading
        case loading
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .notInstalled: "Not installed"
            case .downloading: "Downloading…"
            case .loading: "Loading…"
            case .ready: "Ready"
            case .failed(let message): message
            }
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
        whisperState = .downloading
        do {
            let config = WhisperKitConfig(
                model: "large-v3-v20240930_626MB",
                verbose: false,
                prewarm: true,
                load: true,
                download: true,
                useBackgroundDownloadSession: true
            )
            whisperState = .loading
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
        speakerState = .downloading
        do {
            let config = PyannoteConfig(download: true, load: true)
            speakerState = .loading
            let kit = try await SpeakerKit(config)
            speakerKit = kit
            speakerState = .ready
            return kit
        } catch {
            speakerState = .failed(error.localizedDescription)
            throw error
        }
    }

    func prepareNeuralVoice() async throws -> TTSKit {
        if let ttsKit { return ttsKit }
        neuralVoiceState = .downloading
        do {
            let config = TTSKitConfig(
                model: .qwen3TTS_0_6b,
                verbose: false,
                useBackgroundDownloadSession: true,
                download: true,
                prewarm: true,
                load: true
            )
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
