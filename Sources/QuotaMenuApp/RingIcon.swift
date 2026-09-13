import AppKit
import QuotaCore

enum RingIcon {
    static func image(snapshot: WeeklySnapshot?, at now: Date, stale: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            let opacity: CGFloat = stale ? 0.45 : 1
            ring(radius: 8.5, width: 2.5, fraction: 1, alpha: 0.17)
            guard let snapshot else {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.black
                ]
                NSString(string: "?").draw(at: NSPoint(x: 8, y: 4), withAttributes: attributes)
                return true
            }
            ring(radius: 8.5, width: 2.5, fraction: snapshot.remainingPercent / 100, alpha: opacity)
            if let time = snapshot.remainingTimeFraction(at: now) {
                ring(radius: 4.75, width: 1.8, fraction: 1, alpha: 0.12)
                ring(radius: 4.75, width: 1.8, fraction: time, alpha: opacity * 0.62)
            }
            return true
        }
        // Template rendering follows the actual menu bar background, including dark wallpapers.
        image.isTemplate = true
        return image
    }

    private static func ring(radius: CGFloat, width: CGFloat, fraction: Double, alpha: CGFloat) {
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
        NSColor.black.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }
}
