import Foundation
import AVFoundation
import AppKit
import SwiftUI

/// Developer check: `Intercept.app/Contents/MacOS/Intercept --selftest <audio|screen> <seconds> <out-file>`
/// records for N seconds with the real pipeline, prints the result's tracks, and quits.
enum SelfTest {
    @MainActor
    static func runIfRequested() {
        let args = CommandLine.arguments
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
            for appearance in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
                let view = HomeView().environmentObject(AppState())
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

        guard let i = args.firstIndex(of: "--selftest"), args.count > i + 3,
              let mode = RecordingMode(rawValue: args[i + 1].hasPrefix("screen") ? "screen" : args[i + 1]),
              let seconds = Double(args[i + 2]) else { return }
        let out = URL(fileURLWithPath: args[i + 3])

        Task {
            let raw = out.deletingLastPathComponent().appendingPathComponent(".selftest.capture.mov")
            // "screenall" records every distinct display; "screenall-mirrors"
            // also records mirrored displays, to exercise the compositor.
            let kind = args[i + 1]
            let session = CaptureSession(mode: mode, displays: kind.hasPrefix("screenall") ? .all : .main, rawURL: raw)
            session.includeMirrors = kind == "screenall-mirrors"
            session.duplicateMainForTest = kind == "screenall-double"
            var stopError = "none"
            session.onUnexpectedStop = { err in stopError = err?.localizedDescription ?? "nil" }
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
                try await Mixdown.run(raw: raw, to: out, fileType: mode.fileType)
                try? FileManager.default.removeItem(at: raw)

                let asset = AVURLAsset(url: out)
                let dur = try await asset.load(.duration).seconds
                var lines = ["selftest OK: \(out.path)", String(format: "duration %.2f s, peak in %.3f, peak out %.3f, displays %d, video %.0fx%.0f", dur, peakIn, peakOut, session.displayCount, session.videoSize.width, session.videoSize.height)]
                lines.append("unexpected stop: \(stopError)")
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

    @MainActor
    private static func runAppTest(seconds: Double, folder: URL) {
        let defaults = UserDefaults.standard
        let savedFolder = defaults.object(forKey: "folder")
        let savedMode = defaults.object(forKey: "mode")
        let state = AppState()
        state.folder = folder
        state.mode = .screen
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
            if state.status == .paused { state.toggle() } else { state.stop() }
            while state.status != .idle, Date().timeIntervalSince(t0) < seconds + 120 {
                note()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            note()
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            log.append("files: \(files)")
            if let f = savedFolder { defaults.set(f, forKey: "folder") } else { defaults.removeObject(forKey: "folder") }
            if let m = savedMode { defaults.set(m, forKey: "mode") } else { defaults.removeObject(forKey: "mode") }
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
