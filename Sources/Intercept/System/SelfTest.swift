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

    private static func report(_ text: String, _ out: URL) {
        print(text)
        try? text.write(to: out.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
    }
}
