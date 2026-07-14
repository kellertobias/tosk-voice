import AVFoundation
import Speech
@testable import ToskVoice
import XCTest

final class AudioSignalProcessorTests: XCTestCase {
    func testLevelMapsNormalSpeechRangeToVisibleMeter() throws {
        let quiet = try buffer(sampleRate: 48_000, frames: 1_024, value: 0.01)
        let loud = try buffer(sampleRate: 48_000, frames: 1_024, value: 0.316)

        XCTAssertEqual(AudioSignalProcessor.level(of: quiet), 0.4, accuracy: 0.02)
        XCTAssertGreaterThan(AudioSignalProcessor.level(of: loud), 0.98)
    }

    func testLevelReturnsZeroForSilence() throws {
        let silence = try buffer(sampleRate: 48_000, frames: 1_024, value: 0)
        XCTAssertEqual(AudioSignalProcessor.level(of: silence), 0)
    }

    func testConvertsHardwareRateForSpeechAnalyzer() throws {
        let input = try buffer(sampleRate: 48_000, frames: 4_800, value: 0.1)
        let outputFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = try XCTUnwrap(AVAudioConverter(from: input.format, to: outputFormat))

        let converted = try XCTUnwrap(AudioSignalProcessor.convert(input, to: outputFormat, using: converter))

        XCTAssertEqual(converted.format.sampleRate, 16_000)
        // AVAudioConverter retains a small priming tail for the next live buffer.
        XCTAssertGreaterThan(converted.frameLength, 1_200)
        XCTAssertLessThan(converted.frameLength, 1_700)
        XCTAssertGreaterThan(AudioSignalProcessor.level(of: converted), 0.5)
    }

    @MainActor
    func testRealtimeTapHandlerDoesNotRequireMainActorExecutor() async throws {
        let input = try buffer(sampleRate: 48_000, frames: 1_024, value: 0.1)
        var continuation: AsyncStream<AnalyzerInput>.Continuation?
        let stream = AsyncStream<AnalyzerInput> { continuation = $0 }
        _ = stream
        let samplesDelivered = expectation(description: "meter samples delivered to main actor")
        let processor = AudioTapProcessor(
            continuation: try XCTUnwrap(continuation),
            converter: nil,
            analysisFormat: input.format
        ) { samples, level in
            XCTAssertFalse(samples.isEmpty)
            XCTAssertGreaterThan(level, 0)
            samplesDelivered.fulfill()
        }
        let invocation = AudioTapInvocation(
            handler: processor.makeHandler(),
            buffer: input,
            time: AVAudioTime(sampleTime: 0, atRate: input.format.sampleRate)
        )

        DispatchQueue.global(qos: .userInitiated).async {
            invocation.run()
        }

        await fulfillment(of: [samplesDelivered], timeout: 2)
    }

    private func buffer(sampleRate: Double, frames: AVAudioFrameCount, value: Float) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?.pointee)
        for index in 0..<Int(frames) { samples[index] = value }
        return buffer
    }
}

private final class AudioTapInvocation: @unchecked Sendable {
    private let handler: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    private let buffer: AVAudioPCMBuffer
    private let time: AVAudioTime

    init(
        handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        buffer: AVAudioPCMBuffer,
        time: AVAudioTime
    ) {
        self.handler = handler
        self.buffer = buffer
        self.time = time
    }

    func run() {
        handler(buffer, time)
    }
}
