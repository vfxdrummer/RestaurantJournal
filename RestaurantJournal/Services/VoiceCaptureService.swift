import Foundation
import AVFoundation
import Speech

@MainActor
final class VoiceCaptureService: NSObject, ObservableObject {
    @Published var isRecording: Bool = false
    @Published var currentTranscript: String = ""

    private var audioRecorder: AVAudioRecorder?
    private var currentFilename: String?

    private let speechRecognizer = SFSpeechRecognizer()

    // MARK: - Permissions

    func requestPermissions() async -> Bool {
        let micGranted = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in cont.resume(returning: granted) }
        }
        let speechGranted = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        return micGranted && speechGranted
    }

    // MARK: - Recording

    func startRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default)
        try session.setActive(true)

        let filename = "voice_\(UUID().uuidString).m4a"
        let url = documentsURL().appendingPathComponent(filename)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.record()
        audioRecorder = recorder
        currentFilename = filename
        isRecording = true
        currentTranscript = ""
    }

    /// Stop recording and transcribe the resulting audio file.
    /// - Returns: (filename relative to Documents, transcript or nil if unavailable)
    func stopRecordingAndTranscribe() async -> (String, String?)? {
        guard let recorder = audioRecorder, let filename = currentFilename else { return nil }
        recorder.stop()
        audioRecorder = nil
        isRecording = false

        let url = documentsURL().appendingPathComponent(filename)
        let transcript = await transcribe(url: url)
        currentTranscript = transcript ?? ""
        return (filename, transcript)
    }

    // MARK: - Transcription

    private func transcribe(url: URL) async -> String? {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else { return nil }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        // Prefer on-device where available for privacy + no network cost
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        return await withCheckedContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if error != nil {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
