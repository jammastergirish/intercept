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
        state.settings.screen = true
        state.settings.audio = true
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
}
