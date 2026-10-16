import AVFoundation
import Foundation
import Speech

/// comp-027 in `sustain-pros-and-cons.json`: Vita AI markets voice input/voice
/// chat for logging across multiple release notes — a hands-free option
/// Sustain doesn't have, useful e.g. right after a meal when picking up the
/// phone to type isn't convenient.
///
/// Wraps the standard `SFSpeechRecognizer` + `AVAudioEngine` live-dictation
/// recipe (install a tap on the input node, feed buffers into a streaming
/// `SFSpeechAudioBufferRecognitionRequest`, read back partial results as they
/// arrive) behind a small start/stop API so callers (`VoiceInputButton`) never
/// touch AVFoundation or Speech directly.
///
/// On-device only: `recognizer.supportsOnDeviceRecognition` is checked and
/// `request.requiresOnDeviceRecognition` is set whenever available, so a
/// logged note's audio never has to leave the device to be transcribed on
/// eligible devices — consistent with this app's general preference for
/// keeping health-adjacent data local wherever the platform allows it (see
/// `WeeklySummaryGenerator`'s on-device-first design for the same instinct
/// applied to a different feature).
@Observable
final class SpeechRecognitionService: NSObject {
    static let shared = SpeechRecognitionService()

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private(set) var isRecording = false
    private(set) var lastError: String?

    /// Requests both permissions voice input needs — speech recognition
    /// (transcription) and microphone access (capturing audio at all). Both
    /// are required; a `false` result means the caller should show its own
    /// "voice input isn't available" state rather than silently doing nothing.
    func requestAuthorization() async -> Bool {
        let speechAuthorized = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechAuthorized else { return false }

        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Starts live transcription. `onUpdate` fires with the full transcript so
    /// far every time the recognizer produces a new partial result — callers
    /// own how that text is applied (replace a field entirely, as
    /// `VoiceInputButton` does, rather than this service assuming
    /// append-vs-replace semantics it can't know the right answer to).
    func startTranscribing(onUpdate: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        guard let recognizer, recognizer.isAvailable else {
            onError("Speech recognition isn't available right now.")
            return
        }
        stopTranscribing()

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            onError("Couldn't access the microphone.")
            return
        }

        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
        }
        self.request = recognitionRequest

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            onError("Couldn't start recording.")
            cleanUp()
            return
        }

        isRecording = true
        lastError = nil

        task = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }
            if let result {
                onUpdate(result.bestTranscription.formattedString)
            }
            if error != nil || (result?.isFinal ?? false) {
                self.stopTranscribing()
            }
        }
    }

    func stopTranscribing() {
        guard isRecording || audioEngine.isRunning else { return }
        cleanUp()
    }

    private func cleanUp() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
