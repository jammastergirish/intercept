import SwiftUI
import AppKit
import GraphiteEmber

// Transcripts in Diwan's style: each turn in a box tinted with the speaker's
// colour, an amber monospaced timestamp, the speaker's name in bold mono
// capitals in their colour, and the words in a serif face. The palette is
// Diwan's (speakerColors.ts / Theme.swift), so a speaker colour means the
// same thing across both apps.

enum SpeakerPalette {
    private static let rgb: [(Double, Double, Double)] = [
        (59, 130, 246), (34, 197, 94), (245, 158, 11), (168, 85, 247),
        (236, 72, 153), (20, 184, 166), (239, 68, 68), (132, 204, 22),
    ]
    static func color(_ i: Int) -> Color {
        let (r, g, b) = rgb[i % rgb.count]
        return Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255)
    }
    static func tint(_ i: Int) -> Color { color(i).opacity(0.16) }
}

/// One turn: timestamp, speaker, words.
struct TranscriptLineRow: View {
    let line: Transcript.Line
    let speakerName: String?
    let colorIndex: Int?
    /// Called with a new name when you double-click the speaker and type one.
    var onRename: ((String) -> Void)?

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 16) {
                Text(Format.length(line.start))
                    .font(.mono(12.5))
                    .foregroundStyle(Theme.emberText)
                if let speakerName { speaker(speakerName) }
            }
            Text(line.text)
                .font(.system(size: 16, design: .serif))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(colorIndex.map(SpeakerPalette.tint) ?? Theme.cardBG, in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder private func speaker(_ name: String) -> some View {
        let color = colorIndex.map(SpeakerPalette.color) ?? Theme.textSecondary
        if editing {
            TextField("Name", text: $draft)
                .textFieldStyle(.plain)
                .font(.mono(12.5, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 180)
                .focused($focused)
                .onSubmit { onRename?(draft); editing = false }
                .onExitCommand { editing = false }
                .onChange(of: focused) { _, now in if !now { editing = false } }
        } else {
            Text(name.uppercased())
                .font(.mono(12.5, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(color)
                .onTapGesture(count: 2) {
                    guard onRename != nil else { return }
                    draft = name.hasPrefix("Speaker ") ? "" : name
                    editing = true
                    focused = true
                }
                .help(onRename != nil ? "Double-click to name this speaker" : "")
        }
    }
}

/// The scrolling list of turns.
private struct TranscriptLines: View {
    let lines: [Transcript.Line]
    let name: (Transcript.Line) -> String?
    let colorIndex: (Transcript.Line) -> Int?
    var onRename: ((String, String) -> Void)?   // (speaker id, new name)

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(lines) { line in
                    TranscriptLineRow(line: line, speakerName: name(line), colorIndex: colorIndex(line),
                                      onRename: onRename.flatMap { rename in
                                          line.speaker.map { id in { rename(id, $0) } }
                                      })
                }
            }
            .padding(20)
        }
    }
}

// MARK: - A saved recording's transcript

struct TranscriptWindow: View {
    @EnvironmentObject var state: AppState
    let recording: URL
    @State private var transcript: Transcript?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.divider)
            if let transcript, !transcript.lines.isEmpty {
                TranscriptLines(
                    lines: transcript.lines,
                    name: { $0.speaker.map(transcript.name(of:)) },
                    colorIndex: { line in
                        transcript.hasSeveralSpeakers ? line.speaker.map(transcript.colorIndex(of:)) : nil
                    },
                    onRename: { id, name in state.nameSpeaker(id, as: name, in: recording) })
            } else {
                emptyState
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(Theme.windowBG)
        .onAppear(perform: reload)
        .onChange(of: state.transcriptVersion) { _, _ in reload() }
    }

    private var isWorking: Bool { state.transcribing.contains(recording) }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(subtitle).font(.mono(10.5)).foregroundStyle(Theme.monoFaint)
            }
            Spacer()
            if isWorking { EmberSpinner(size: 13) }
            if let transcript, !transcript.lines.isEmpty {
                Button("Copy text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcript.plainText, forType: .string)
                }
                .buttonStyle(EmberLinkButtonStyle())
            }
            Button(transcript == nil ? "Transcribe" : "Re-transcribe") { state.transcribe(recording) }
                .buttonStyle(EmberLinkButtonStyle())
                .disabled(isWorking || !state.hasAPIKey)
        }
        .padding(.horizontal, 20)
        .padding(.top, 30)       // below the traffic lights
        .padding(.bottom, 12)
    }

    private var subtitle: String {
        if isWorking { return "TRANSCRIBING WITH ELEVENLABS…" }
        guard let transcript else { return "NO TRANSCRIPT YET" }
        let speakers = transcript.speakers.count
        let who = speakers > 1 ? " · \(speakers) SPEAKERS · DOUBLE-CLICK A NAME TO CHANGE IT" : ""
        return "\(transcript.lines.count) LINES" + who
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            if isWorking {
                EmberSpinner(size: 18)
                Text("Transcribing…").foregroundStyle(Theme.textSecondary)
            } else if let problem = state.transcriptProblem {
                Text(problem).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            } else {
                Text(state.hasAPIKey ? "Press Transcribe to make a transcript."
                                     : "Add your ElevenLabs key in the main window to transcribe.")
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity)
        .padding(30)
    }

    private func reload() { transcript = Transcript.load(for: recording) }
}

// MARK: - Adding the API key

struct APIKeySheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MonoLabel(text: "ElevenLabs API key", size: 12, tracking: 0.8, color: Theme.textPrimary)
            Text("Intercept sends the sound of recordings you transcribe to ElevenLabs. The key is kept in your Mac's Keychain.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField(state.hasAPIKey ? "Paste a new key to replace the saved one" : "Paste your key", text: $key)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if failed {
                Text("Couldn't save the key to the Keychain.").font(.system(size: 11.5)).foregroundStyle(Theme.emberText)
            }
            HStack {
                if state.hasAPIKey {
                    Button("Remove key") { state.removeAPIKey(); dismiss() }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(key.isEmpty)
            }
            .buttonStyle(GraphiteButtonStyle())
        }
        .padding(20)
        .frame(width: 400)
        .background(Theme.windowBG)
    }

    private func save() {
        if state.setAPIKey(key) { dismiss() } else { failed = true }
    }
}
