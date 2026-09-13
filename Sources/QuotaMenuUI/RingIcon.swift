import AppKit
import QuotaCore

public enum RingIcon {
    public static func image(snapshot: WeeklySnapshot?, at now: Date, stale: Bool,
                             appearance: NSAppearance) -> NSImage {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let neutral = NSColor(white: dark ? 0.92 : 0.12, alpha: 1)
        let quota = snapshot.map { stale ? neutral : quotaColor(remaining: $0.remainingPercent, dark: dark) }
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            // NSImage draws lazily; keep appearance resolution scoped to the actual draw.
            appearance.performAsCurrentDrawingAppearance {
                // A colored track also keeps a fresh, exhausted (0%) reading visibly red.
                ring(radius: 8.5, width: 2.5, fraction: 1,
                     color: (quota ?? neutral).withAlphaComponent(stale ? 0.12 : 0.25))
                guard let snapshot, let quota else {
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                        .foregroundColor: neutral.withAlphaComponent(0.8)
                    ]
                    NSString(string: "?").draw(at: NSPoint(x: 8, y: 4), withAttributes: attributes)
                    return
                }
                ring(radius: 8.5, width: 2.5, fraction: snapshot.remainingPercent / 100,
                     color: quota.withAlphaComponent(stale ? 0.45 : 1))
                if let time = snapshot.remainingTimeFraction(at: now) {
                    ring(radius: 4.75, width: 1.8, fraction: 1,
                         color: neutral.withAlphaComponent(stale ? 0.10 : 0.18))
                    ring(radius: 4.75, width: 1.8, fraction: time,
                         color: neutral.withAlphaComponent(stale ? 0.35 : 0.75))
                }
            }
            return true
        }
        // Template images discard RGB. Keep percentage text on the native status button.
        image.isTemplate = false
        return image
    }

    private static func quotaColor(remaining: Double, dark: Bool) -> NSColor {
        let rgb: (CGFloat, CGFloat, CGFloat)
        switch remaining {
        case 80...: rgb = dark ? (0.27, 0.86, 0.47) : (0.06, 0.46, 0.21)
        case 50..<80: rgb = dark ? (0.48, 0.88, 0.78) : (0.10, 0.57, 0.48)
        case 20..<50: rgb = dark ? (1.00, 0.74, 0.25) : (0.69, 0.40, 0.03)
        default: rgb = dark ? (1.00, 0.38, 0.36) : (0.80, 0.16, 0.15)
        }
        return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }

    private static func ring(radius: CGFloat, width: CGFloat, fraction: Double, color: NSColor) {
        guard fraction > 0 else { return }
        let path = NSBezierPath()
        if fraction >= 1 {
            path.appendOval(in: NSRect(x: 11 - radius, y: 11 - radius, width: radius * 2, height: radius * 2))
        } else {
            path.appendArc(withCenter: NSPoint(x: 11, y: 11), radius: radius,
                           startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
            path.lineCapStyle = .round
        }
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }
}
