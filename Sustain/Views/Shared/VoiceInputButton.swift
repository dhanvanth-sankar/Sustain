import SwiftUI

/// A small mic button that dictates directly into a bound text field —
/// comp-027 in `sustain-pros-and-cons.json`. Drop this next to any
/// `TextField`/`TextEditor` that should support hands-free input; it replaces
/// `text` with the live transcript while recording (not append) and stops on
/// a second tap, matching how the system dictation key on the keyboard itself
/// behaves.
struct VoiceInputButton: View {
    @Binding var text: String

    @State private var speech = SpeechRecognitionService.shared
    @State private var errorMessage: String?

    /// Captured once, when recording starts, so a mid-recording transcript
    /// replaces only what was said during *this* recording — without this, a
    /// second recording appended onto its own live-updating text would
    /// re-insert earlier partial transcripts as new speech arrived, since
    /// `onUpdate` always receives the full transcript for the current
    /// recognition task, not a delta.
    @State private var textBeforeRecording = ""

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                toggle()
            } label: {
                Image(systemName: speech.isRecording ? "mic.fill" : "mic")
                    .foregroundStyle(speech.isRecording ? Theme.danger : Theme.primary)
                    .symbolEffect(.pulse, isActive: speech.isRecording)
            }
            .buttonStyle(.plain)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func toggle() {
        if speech.isRecording {
            speech.stopTranscribing()
            return
        }

        textBeforeRecording = text
        Task {
            let authorized = await speech.requestAuthorization()
            guard authorized else {
                errorMessage = "Enable microphone and speech recognition access in Settings to use voice input."
                return
            }
            errorMessage = nil
            speech.startTranscribing(
                onUpdate: { transcript in
                    let separator = textBeforeRecording.isEmpty ? "" : " "
                    text = textBeforeRecording + separator + transcript
                },
                onError: { message in
                    errorMessage = message
                }
            )
        }
    }
}

#Preview {
    @Previewable @State var text = ""
    return HStack {
        TextField("Notes", text: $text)
        VoiceInputButton(text: $text)
    }
    .padding()
}
