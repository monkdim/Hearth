import AVFoundation
import Foundation
import Observation
import WhisperKit
import os

@MainActor
@Observable
final class VoiceInputService: NSObject {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
    }

    private let logger = Logger(subsystem: "com.colbydimaggio.hearth", category: "VoiceInput")
    private(set) var state: State = .idle
    /// Most recent transcription error (or empty string when none).
    private(set) var lastError: String = ""

    private var pipe: WhisperKit?
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    /// Whisper variant to use. Smaller = faster but less accurate.
    /// Persisted in UserDefaults.
    var modelName: String {
        didSet {
            UserDefaults.standard.set(modelName, forKey: Self.modelKey)
            // Force re-creation on next use if the model changed.
            pipe = nil
        }
    }
    private static let modelKey = "hearth.whisperModel"

    /// Default — small enough for any Mac, decent accuracy.
    static let defaultModelName = "openai_whisper-small"

    /// Common WhisperKit-hosted model variants (Apple Silicon Core ML).
    static let availableModels: [(id: String, label: String, sizeMB: Int)] = [
        ("openai_whisper-tiny",   "Tiny (~75 MB)",   75),
        ("openai_whisper-base",   "Base (~150 MB)",  150),
        ("openai_whisper-small",  "Small (~470 MB)", 470),
        ("openai_whisper-medium", "Medium (~1.5 GB)", 1500),
        ("openai_whisper-large-v3", "Large v3 (~3 GB)", 3000),
    ]

    override init() {
        self.modelName = UserDefaults.standard.string(forKey: Self.modelKey) ?? Self.defaultModelName
        super.init()
    }

    /// One-time mic permission request. Returns whether granted.
    func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Recording

    /// Start a fresh recording. Returns true if recording began.
    @discardableResult
    func startRecording() -> Bool {
        guard state == .idle else { return false }
        lastError = ""

        let dir = FileManager.default.temporaryDirectory
        let url = dir.appending(path: "hearth-voice-\(UUID().uuidString.prefix(8)).m4a")
        recordingURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000.0,        // Whisper expects 16k
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.delegate = self
            guard recorder?.record() == true else {
                lastError = "Couldn't start recorder."
                return false
            }
            state = .recording
            return true
        } catch {
            lastError = error.localizedDescription
            recorder = nil
            recordingURL = nil
            return false
        }
    }

    /// Stop recording and transcribe. Returns the transcribed text, or nil on failure.
    func stopAndTranscribe() async -> String? {
        guard state == .recording else { return nil }
        recorder?.stop()
        state = .transcribing
        guard let url = recordingURL else {
            state = .idle
            return nil
        }
        defer {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
            recorder = nil
        }

        do {
            let pipeline = try await ensurePipe()
            let results = try await pipeline.transcribe(audioPath: url.path)
            let text = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            state = .idle
            return text.isEmpty ? nil : text
        } catch {
            lastError = error.localizedDescription
            logger.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            state = .idle
            return nil
        }
    }

    /// Abort an in-progress recording without transcribing.
    func cancelRecording() {
        guard state == .recording else { return }
        recorder?.stop()
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        recorder = nil
        state = .idle
    }

    // MARK: - Internals

    private func ensurePipe() async throws -> WhisperKit {
        if let pipe { return pipe }
        let config = WhisperKitConfig(model: modelName, load: true, download: true)
        let pipeline = try await WhisperKit(config)
        pipe = pipeline
        return pipeline
    }
}

extension VoiceInputService: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            self.lastError = error.localizedDescription
            self.state = .idle
        }
    }
}
