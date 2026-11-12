import Foundation
import AVFoundation
import AppKit
import SwiftUI
import GraphiteEmber
import ScreenCaptureKit

/// Developer check: `Intercept.app/Contents/MacOS/Intercept --selftest <audio|screen> <seconds> <out-file>`
/// records for N seconds with the real pipeline, prints the result's tracks, and quits.
enum SelfTest {
    @MainActor
    static func runIfRequested() {
        let args = CommandLine.arguments
        // `--windows <file>`: list the windows ScreenCaptureKit can see, and quit.
        if let i = args.firstIndex(of: "--windows"), args.count > i + 1 {
            let out = URL(fileURLWithPath: args[i + 1])
            Task {
                var lines: [String] = []
                do {
                    let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    for w in c.windows {
                        let f = w.frame
                        lines.append(String(format: "%@ | %@ | layer %d | %.0f,%.0f %.0fx%.0f | onscreen %d | active %d | title=%@",
                            w.owningApplication?.bundleIdentifier ?? "-", w.owningApplication?.applicationName ?? "-",
                            w.windowLayer, f.minX, f.minY, f.width, f.height, w.isOnScreen ? 1 : 0, w.isActive ? 1 : 0, w.title ?? ""))
                    }
                } catch { lines.append("error: \(error.localizedDescription)") }
                try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
                exit(0)
            }
            return
        }
        // `--apptest <seconds> <folder>`: drive the real AppState (start, wait,
        // stop) into a folder, logging every status change, then quit.
        if let i = args.firstIndex(of: "--apptest"), args.count > i + 2, let seconds = Double(args[i + 1]) {
            runAppTest(seconds: seconds, folder: URL(fileURLWithPath: args[i + 2], isDirectory: true))
            return
        }
        // `--transcribe <file>`: transcribe a recording with ElevenLabs, save the
        // transcript beside it, write a summary to <file>.scribe.txt, and quit.
        if let i = args.firstIndex(of: "--transcribe"), args.count > i + 1 {
            let file = URL(fileURLWithPath: args[i + 1])
            Task {
                var out: String
                do {
                    let t = try await Scribe.transcribe(file)
                    try t.save(for: file)
                    out = "OK model \(t.model), \(t.lines.count) lines, speakers \(t.speakers)\n" + t.plainText
                } catch {
                    out = "FAILED: \(error.localizedDescription)"
                }
                try? out.write(to: file.appendingPathExtension("scribe.txt"), atomically: true, encoding: .utf8)
                exit(0)
            }
            return
        }
        // `--name-and-rename <file> <speaker id> <name> <new file name>`: name a
        // speaker in a recording's transcript, rename the recording, report.
        if let i = args.firstIndex(of: "--name-and-rename"), args.count > i + 4 {
            let file = URL(fileURLWithPath: args[i + 1])
            let state = AppState()
            state.nameSpeaker(args[i + 2], as: args[i + 3], in: file)
            let item = RecordingItem(url: file, date: Date(), bytes: file.fileSize)
            let ok = state.rename(item, to: args[i + 4])
            let renamed = file.deletingLastPathComponent().appendingPathComponent(args[i + 4])
                .appendingPathExtension(file.pathExtension)
            let t = Transcript.load(for: renamed)
            let report = "rename ok: \(ok)\nnames: \(t?.speakerNames ?? [:])\n" + (t?.plainText ?? "no transcript at new name")
            try? report.write(to: file.deletingLastPathComponent().appendingPathComponent("rename-test.txt"),
                              atomically: true, encoding: .utf8)
            exit(0)
        }
        // `--marketing-shots <recordings folder> <out prefix>`: render the main
        // window (light and dark) with sample recordings and generic device
        // names, and a sample transcript, for the website. Then quit.
        if let i = args.firstIndex(of: "--marketing-shots"), args.count > i + 2 {
            let folder = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            let prefix = args[i + 2]
            let savedFolder = UserDefaults.standard.object(forKey: "folder")
            let state = AppState()
            let saved = SettingsStore.load()
            state.prepareForScreenshot(folder: folder)
            state.settings = CaptureSettings(screen: true, audio: true, camera: true, transcribe: true)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)   // let the list load
                for dark in [false, true] {
                    NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let scheme: ColorScheme = dark ? .dark : .light
                    let suffix = dark ? "dark" : "light"
                    render(HomeView().environmentObject(state).environment(\.colorScheme, scheme),
                           to: "\(prefix)window-\(suffix).png")
                    render(sampleTranscript(scheme), to: "\(prefix)transcript-\(suffix).png")
                }
                SettingsStore.save(saved)
                if let savedFolder { UserDefaults.standard.set(savedFolder, forKey: "folder") }
                else { UserDefaults.standard.removeObject(forKey: "folder") }
                exit(0)
            }
            return
        }
        // `--recover <folder>`: finish leftover capture files in a folder and quit.
        if let i = args.firstIndex(of: "--recover"), args.count > i + 1 {
            let folder = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            Task {
                let r = await Recovery.run(in: folder)
                let text = "recovered: \(r.recovered.map(\.lastPathComponent))\nfailed: \(r.failed.map(\.lastPathComponent))"
                print(text)
                try? text.write(to: folder.appendingPathComponent("recover.txt"), atomically: true, encoding: .utf8)
                exit(0)
            }
            return
        }
        // `--snapshot <png>`: render the main window's view to an image and quit.
        if let i = args.firstIndex(of: "--snapshot"), args.count > i + 1 {
          let state = AppState()
          state.refreshRecordings()
          Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)   // let the recordings list load
            for appearance in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
                let view = HomeView().environmentObject(state)
                    .environment(\.colorScheme, appearance == "light" ? .light : .dark)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: args[i + 1] + "-\(appearance).png"))
                }
            }
            exit(0)
          }
          return
        }

        guard let i = args.firstIndex(of: "--selftest"), args.count > i + 3,
              let seconds = Double(args[i + 2]) else { return }
        let kind = args[i + 1]
        let settings = testSettings(kind)
        let out = URL(fileURLWithPath: args[i + 3])

        Task {
            let raw = out.deletingLastPathComponent().appendingPathComponent(".selftest.capture.mov")
            let session = CaptureSession(settings: settings, rawURL: raw)
            session.includeMirrors = kind.contains("mirrors")
            session.duplicateMainForTest = kind.contains("double")
            var stopError = "none"
            session.onUserStopped = { stopError = "stopped from the macOS menu" }
            do {
                try await session.start()
                var peakIn: Float = 0, peakOut: Float = 0
                let end = Date().addingTimeInterval(seconds)
                while Date() < end {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    let l = session.takeLevels()
                    peakIn = max(peakIn, l.input); peakOut = max(peakOut, l.output)
                }
                _ = try await session.stop()
                try await Mixdown.run(raw: raw, to: out, fileType: settings.fileType)
                try? FileManager.default.removeItem(at: raw)

                let asset = AVURLAsset(url: out)
                let dur = try await asset.load(.duration).seconds
                var lines = ["selftest OK: \(out.path)", String(format: "duration %.2f s, peak in %.3f, peak out %.3f, displays %d, video %.0fx%.0f", dur, peakIn, peakOut, session.displayCount, session.videoSize.width, session.videoSize.height)]
                lines.append("unexpected stop: \(stopError), display went away \(session.videoInterruptions) time(s)")
                for t in try await asset.load(.tracks) {
                    let size = try await t.load(.naturalSize)
                    lines.append("track \(t.mediaType.rawValue) \(Int(size.width))x\(Int(size.height))")
                }
                report(lines.joined(separator: "\n"), out)
            } catch {
                report("selftest FAILED: \(error.localizedDescription)", out)
            }
            fflush(stdout)
            exit(0)
        }
    }

    /// What a self-test records. Either a word joined with "+", e.g.
    /// "screen+audio+camera", "camera+nomic", "screen+all+double", or one of
    /// the older names: "audio", "screen" (screen + audio), "screenonly",
    /// "screenall", "screenall-double", "screenall-mirrors".
    private static func testSettings(_ kind: String) -> CaptureSettings {
        var s = CaptureSettings()
        let legacy: [String: String] = [
            "audio": "audio", "screen": "screen+audio", "screenonly": "screen",
            "screenall": "screen+audio+all", "screenall-double": "screen+audio+all+double",
            "screenall-mirrors": "screen+audio+all+mirrors",
        ]
        let words = Set((legacy[kind] ?? kind).split(separator: "+").map(String.init))
        s.screen = words.contains("screen")
        s.audio = words.contains("audio")
        s.camera = words.contains("camera")
        s.displays = words.contains("all") ? .all : .main
        s.useMic = !words.contains("nomic")
        s.macSound = !words.contains("nosound")
        return s
    }

    @MainActor
    private static func runAppTest(seconds: Double, folder: URL) {
        let defaults = UserDefaults.standard
        let savedFolder = defaults.object(forKey: "folder")
        let saved = SettingsStore.load()
        let state = AppState()
        state.folder = folder
        let withTranscribe = CommandLine.arguments.contains("--with-transcribe")
        state.settings.screen = !withTranscribe
        state.settings.audio = true
        state.settings.camera = false
        state.settings.transcribe = withTranscribe
        let t0 = Date()
        var log: [String] = []
        var last = ""
        func note() {
            let s = "\(state.status)"
            if s != last { log.append(String(format: "%6.1f s  %@", Date().timeIntervalSince(t0), s)); last = s }
        }
        Task { @MainActor in
            state.start()
            while Date().timeIntervalSince(t0) < seconds {
                note()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            note()
            state.stop()
            while state.status != .idle, Date().timeIntervalSince(t0) < seconds + 120 {
                note()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            note()
            // Wait for the full transcription to finish, if one started.
            while !state.transcribing.isEmpty, Date().timeIntervalSince(t0) < seconds + 300 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if !state.transcribing.isEmpty { log.append("transcription still running") }
            if let p = state.transcriptProblem { log.append("transcript problem: \(p)") }
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            log.append("files: \(files)")
            if let f = savedFolder { defaults.set(f, forKey: "folder") } else { defaults.removeObject(forKey: "folder") }
            SettingsStore.save(saved)
            let text = log.joined(separator: "\n")
            print(text)
            try? text.write(to: folder.appendingPathComponent("apptest.txt"), atomically: true, encoding: .utf8)
            exit(0)
        }
    }

    private static func report(_ text: String, _ out: URL) {
        print(text)
        try? text.write(to: out.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
    }

    @MainActor
    private static func render(_ view: some View, to path: String) {
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    /// A short made-up conversation, laid out like the transcript window.
    @MainActor
    private static func sampleTranscript(_ scheme: ColorScheme) -> some View {
        var t = Transcript(lines: [
            .init(id: 0, start: 0, end: 4, speaker: "speaker_0", text: "Thanks for making time. Shall we start with the launch plan?"),
            .init(id: 1, start: 4, end: 9, speaker: "speaker_1", text: "Yes. The beta goes out on Thursday, and the release notes are nearly done."),
            .init(id: 2, start: 9, end: 13, speaker: "speaker_0", text: "Great. Who's writing the announcement?"),
            .init(id: 3, start: 13, end: 19, speaker: "speaker_2", text: "I can take that. I'll have a draft by Wednesday morning."),
        ], model: "scribe_v2")
        t.speakerNames = ["speaker_0": "Alex", "speaker_1": "Sam"]
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch planning").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("4 LINES · 3 SPEAKERS · DOUBLE-CLICK A NAME TO CHANGE IT").font(.mono(10.5)).foregroundStyle(Theme.monoFaint)
                }
                Spacer()
                Text("Copy text").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.emberText)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.emberTint, in: RoundedRectangle(cornerRadius: 5))
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider().overlay(Theme.divider)
            VStack(spacing: 6) {
                ForEach(t.lines) { line in
                    TranscriptLineRow(line: line, speakerName: line.speaker.map(t.name(of:)),
                                      colorIndex: line.speaker.map(t.colorIndex(of:)))
                }
            }
            .padding(20)
        }
        .frame(width: 620)
        .background(Theme.windowBG)
        .environment(\.colorScheme, scheme)
    }
}
