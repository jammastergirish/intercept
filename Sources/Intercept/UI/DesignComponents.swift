import SwiftUI
import AppKit

// Components shared with One Tap Transcribe's "Graphite & Ember" design.

// MARK: - Status badge (READY / RECORDING)

struct StatusBadge: View {
    var text: String
    var color: Color = Theme.emberText
    var tint: Color = Theme.emberTint

    var body: some View {
        Text(text.uppercased())
            .font(.mono(10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint, in: RoundedRectangle(cornerRadius: 4))
    }
}

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

// MARK: - Logo squircle

struct LogoSquircle: View {
    var side: CGFloat = 24
    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.23, style: .continuous)
            .fill(Theme.squircleBG)
            .frame(width: side, height: side)
            .overlay(RecordGlyph(side: side * 0.56))
    }
}

// MARK: - Ember spinner

struct EmberSpinner: View {
    var size: CGFloat = 14
    @State private var angle: Double = 0
    var body: some View {
        ZStack {
            Circle().stroke(Theme.ember.opacity(0.35), lineWidth: 2)
            Circle().trim(from: 0, to: 0.3)
                .stroke(Theme.ember, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(angle))
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) { angle = 360 }
        }
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

// MARK: - Segmented picker

struct Segment<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    let systemImage: String?
    var id: Value { value }
}

struct SegmentPicker<Value: Hashable>: View {
    let segments: [Segment<Value>]
    @Binding var selection: Value
    var disabled: Bool = false
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { seg in
                let selected = seg.value == selection
                Button {
                    selection = seg.value
                } label: {
                    HStack(spacing: 6) {
                        if let icon = seg.systemImage {
                            Image(systemName: icon).font(.system(size: compact ? 10 : 11, weight: .medium))
                        }
                        Text(seg.title).font(.system(size: compact ? 11.5 : 12.5, weight: selected ? .semibold : .regular))
                    }
                    .foregroundStyle(selected ? Theme.emberText : Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, compact ? 4 : 6)
                    .background(selected ? Theme.cardBG : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(selected ? Theme.fieldBorder : Color.clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.checkboxOff, in: RoundedRectangle(cornerRadius: 8))
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
    }
}

// MARK: - Ghost/bordered button style ("Folder…", "Quit")

struct GraphiteButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Theme.buttonBG, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.fieldBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Small ember-text link-style button ("Grant", "Reveal").
struct EmberLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.emberText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.emberTint, in: RoundedRectangle(cornerRadius: 5))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Drawn artwork (app icon + menu-bar icon)

enum AppArtwork {
    /// Near-black squircle with an ember ring and record dot.
    static func appIcon(side: CGFloat = 512) -> NSImage {
        let img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()
        let inset = side * 0.055
        let rect = NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
        NSColor(Theme.squircleBG).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.23, yRadius: rect.width * 0.23).fill()
        drawMark(in: rect, color: NSColor(Theme.ember), ringFraction: 0.27, dotFraction: 0.15, lineFraction: 0.055)
        img.unlockFocus()
        return img
    }

    /// Monochrome template mark for the menu bar. `filled` while recording.
    static func menuBarIcon(recording: Bool) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let img = NSImage(size: size)
        img.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        if recording {
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
        } else {
            drawMark(in: rect, color: .black, ringFraction: 0.42, dotFraction: 0.2, lineFraction: 0.11)
        }
        img.unlockFocus()
        img.isTemplate = true
        return img
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
