import AppKit
import QuotaCore
import QuotaMenuUI

struct RingIconTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(_ remaining: Double) -> WeeklySnapshot {
        WeeklySnapshot(usedPercent: 100 - remaining, resetsAt: now.addingTimeInterval(302_400),
                       windowDurationMins: 10_080, fetchedAt: now)
    }

    private func bitmap(width: Int, height: Int, draw: () -> Void) throws -> NSBitmapImageRep {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw CheckFailure(message: "Cannot create AppKit bitmap", file: #filePath, line: #line)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw()
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private func render(_ remaining: Double?, stale: Bool = false, dark: Bool) throws -> NSBitmapImageRep {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let icon = RingIcon.image(snapshot: remaining.map(snapshot), at: now, stale: stale, appearance: appearance)
        try expect(!icon.isTemplate, "Template rendering would discard the quota color")
        // Deliberately draw under the opposite ambient appearance, as an offscreen image can be.
        return try bitmap(width: 44, height: 44) {
            NSAppearance(named: dark ? .aqua : .darkAqua)!.performAsCurrentDrawingAppearance {
                icon.draw(in: NSRect(x: 0, y: 0, width: 44, height: 44))
            }
        }
    }

    private func strongestPixel(_ bitmap: NSBitmapImageRep, radius: ClosedRange<Double>) throws -> NSColor {
        var strongest: NSColor?
        for y in 0..<44 {
            for x in 0..<44 {
                let distance = hypot((Double(x) + 0.5) / 2 - 11, (Double(y) + 0.5) / 2 - 11)
                guard radius.contains(distance), let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if pixel.alphaComponent > (strongest?.alphaComponent ?? 0) { strongest = pixel }
            }
        }
        guard let strongest else {
            throw CheckFailure(message: "Expected visible pixels in ring", file: #filePath, line: #line)
        }
        return strongest
    }

    func thresholdColors() throws {
        let cases: [(Double, String)] = [(0, "red"), (19.999, "red"), (20, "amber"),
                                         (49.999, "amber"), (50, "teal"), (79.999, "teal"),
                                         (80, "green"), (100, "green")]
        for dark in [false, true] {
            for (remaining, expected) in cases {
                let color = try strongestPixel(render(remaining, dark: dark), radius: 7.6...9.4)
                let (r, g, b) = (color.redComponent, color.greenComponent, color.blueComponent)
                let actual: String
                if r > g * 1.7, abs(g - b) < 0.1 { actual = "red" }
                else if r > g, g > b + 0.2 { actual = "amber" }
                else if g > r, b / g > 0.65 { actual = "teal" }
                else if g > r, b / g < 0.65 { actual = "green" }
                else { actual = "unrecognized RGB \(r), \(g), \(b)" }
                try expect(actual == expected, "\(remaining)% dark=\(dark): expected \(expected), got \(actual)")
                try expect(color.alphaComponent >= 0.24, "Even an exhausted reading needs a visible red track")
            }
        }
    }

    func neutralTimeUnknownAndStale() throws {
        for dark in [false, true] {
            for remaining: Double? in [0, 20, 50, 80, 100, nil] {
                let fresh = try render(remaining, dark: dark)
                let stale = try render(remaining, stale: true, dark: dark)
                let staleOuter = try strongestPixel(stale, radius: 7.6...9.4)
                try expect(isNeutral(staleOuter), "Stale quota must not retain a fresh color")
                let unknownOrTime = try strongestPixel(fresh, radius: remaining == nil ? 0...6 : 4.2...5.3)
                try expect(isNeutral(unknownOrTime), "Time / question mark must stay neutral")
                try expect(dark ? unknownOrTime.redComponent > 0.8 : unknownOrTime.redComponent < 0.25,
                           "Neutral detail must follow the requested menu-bar appearance")
                if remaining != nil {
                    let freshOuter = try strongestPixel(fresh, radius: 7.6...9.4)
                    try expect(staleOuter.alphaComponent < freshOuter.alphaComponent, "Stale ring must be dimmed")
                    let staleTime = try strongestPixel(stale, radius: 4.2...5.3)
                    try expect(staleTime.alphaComponent < unknownOrTime.alphaComponent, "Stale time must be dimmed")
                } else {
                    try expect(isNeutral(strongestPixel(fresh, radius: 7.6...9.4)), "Unknown must not imply a quota band")
                }
            }
        }
    }

    private func isNeutral(_ color: NSColor) -> Bool {
        abs(color.redComponent - color.greenComponent) < 0.02 &&
        abs(color.greenComponent - color.blueComponent) < 0.02
    }

    /// Synthetic data only. Includes true 22-point icons and enlarged copies on both backgrounds.
    func writePreview(to path: String) throws {
        let remaining: [Double?] = [0, 10, 20, 50, 80, 100, nil, 80]
        let labels = ["0%", "10%", "20%", "50%", "80%", "100%", "Unknown", "80% stale"]
        let width = remaining.count * 120
        let preview = try bitmap(width: width, height: 400) {
            for (row, dark) in [false, true].enumerated() {
                let origin = CGFloat(1 - row) * 200
                NSColor(white: dark ? 0.09 : 0.96, alpha: 1).setFill()
                NSRect(x: 0, y: origin, width: CGFloat(width), height: 200).fill()
                let text = NSColor(white: dark ? 0.95 : 0.08, alpha: 1)
                NSString(string: dark ? "Dark menu bar" : "Light menu bar").draw(
                    at: NSPoint(x: 14, y: origin + 174),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: text])
                for column in remaining.indices {
                    let x = CGFloat(column) * 120 + 16
                    let icon = RingIcon.image(snapshot: remaining[column].map(snapshot), at: now,
                                              stale: column == remaining.count - 1,
                                              appearance: NSAppearance(named: dark ? .darkAqua : .aqua)!)
                    icon.draw(in: NSRect(x: x, y: origin + 128, width: 22, height: 22))
                    NSString(string: labels[column]).draw(at: NSPoint(x: x + 27, y: origin + 133),
                        withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: text])
                    icon.draw(in: NSRect(x: x + 4, y: origin + 20, width: 88, height: 88))
                }
            }
        }
        guard let png = preview.representation(using: .png, properties: [:]) else {
            throw CheckFailure(message: "Cannot encode ring preview", file: #filePath, line: #line)
        }
        try png.write(to: URL(fileURLWithPath: path))
        print("Synthetic light/dark ring preview: \(path)")
    }
}
