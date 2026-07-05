import SwiftUI
import SwiftData

struct VoiceRecorderSheet: View {
    let visit: Visit
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @StateObject private var capture = VoiceCaptureService()
    @State private var errorText: String?
    @State private var isFinalizing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()
                Image(systemName: capture.isRecording ? "waveform" : "mic.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(capture.isRecording ? .red : .accentColor)
                    .symbolEffect(.pulse, isActive: capture.isRecording)

                Text(capture.isRecording ? "Recording…" : (isFinalizing ? "Transcribing…" : "Tap to record"))
                    .font(.title3)

                if !capture.currentTranscript.isEmpty {
                    Text(capture.currentTranscript)
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Spacer()

                Button {
                    Task { await toggle() }
                } label: {
                    Text(capture.isRecording ? "Stop" : "Record")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(capture.isRecording ? Color.red : Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)
                .disabled(isFinalizing)

                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.caption)
                }
            }
            .padding()
            .navigationTitle("Voice note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func toggle() async {
        if capture.isRecording {
            isFinalizing = true
            defer { isFinalizing = false }
            if let (filename, transcript) = await capture.stopRecordingAndTranscribe() {
                let note = VoiceNote(audioFilename: filename, recordedAt: Date(), transcript: transcript)
                note.visit = visit
                modelContext.insert(note)
                try? modelContext.save()
                dismiss()
            }
        } else {
            let ok = await capture.requestPermissions()
            guard ok else {
                errorText = "Microphone and Speech permissions are required."
                return
            }
            do {
                try capture.startRecording()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
