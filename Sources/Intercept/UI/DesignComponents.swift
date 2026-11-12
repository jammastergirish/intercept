import SwiftUI
import AppKit
import GraphiteEmber

// Intercept's own pieces. The shared theme and components come from the
// GraphiteEmber package.

// MARK: - Record mark (ember ring + dot)

struct RecordGlyph: View {
    var side: CGFloat = 14
    var color: Color = Theme.ember

    var body: some View {
        ZStack {
            Circle().stroke(color, lineWidth: side * 0.11)
            Circle().fill(color).frame(width: side * 0.52, height: side * 0.52)
        }
        .frame(width: side, height: side)
    }
}

extension LogoSquircle where Mark == RecordGlyph {
    /// The squircle with Intercept's record mark.
    init(side: CGFloat = 24) {
        self.init(side: side) { RecordGlyph(side: $0 * 0.56) }
    }
}

// MARK: - Level meter (segmented ember bar)

struct LevelMeter: View {
    var label: String
    var level: Float          // 0...1
    var segments: Int = 14

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.mono(10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.overlayDim)
                .frame(width: 28, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(0..<segments, id: \.self) { i in
                    let lit = Float(i) / Float(segments) < level && level > 0.01
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(lit ? Theme.ember : Color.white.opacity(0.10))
                        .frame(width: 5, height: 10)
                }
            }
        }
    }
}

// MARK: - Drawn artwork (app icon + menu-bar icon)

enum AppArtwork {
    /// Near-black squircle with an ember ring and record dot.
    static func appIcon() -> NSImage {
        SquircleIcon.image(mark: drawAppMark)
    }

    /// Handles the build script's `--write-iconset <folder>` launch flag.
    static func writeIconsetIfRequested() {
        SquircleIcon.writeIconsetIfRequested(mark: drawAppMark)
    }

    /// Monochrome template mark for the menu bar. Solid dot while recording.
    static func menuBarIcon(recording: Bool) -> NSImage {
        SquircleIcon.template(size: NSSize(width: 16, height: 16)) { rect in
            if recording {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            } else {
                drawMark(in: rect, color: .black, ringFraction: 0.42, dotFraction: 0.2, lineFraction: 0.11)
            }
        }
    }

    private static func drawAppMark(in rect: NSRect) {
        drawMark(in: rect, color: NSColor(Theme.ember), ringFraction: 0.27, dotFraction: 0.15, lineFraction: 0.055)
    }

    private static func drawMark(in rect: NSRect, color: NSColor,
                                 ringFraction: CGFloat, dotFraction: CGFloat, lineFraction: CGFloat) {
        let ringR = rect.width * ringFraction
        let ring = NSBezierPath(ovalIn: NSRect(x: rect.midX - ringR, y: rect.midY - ringR, width: 2 * ringR, height: 2 * ringR))
        ring.lineWidth = rect.width * lineFraction
        color.setStroke()
        ring.stroke()
        let dotR = rect.width * dotFraction
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.midX - dotR, y: rect.midY - dotR, width: 2 * dotR, height: 2 * dotR)).fill()
    }
}
