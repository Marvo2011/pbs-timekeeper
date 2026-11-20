import AppKit

/// Menu bar icons. The status item shows a static image, SwiftUI animations do not run there,
/// so a running backup is animated by switching between pre-rendered rotated frames.
@MainActor
enum MenuBarIcon {
    static let frameCount = 12
    static let frameInterval: Duration = .milliseconds(80)

    static func symbol(_ name: String) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "PBS Timekeeper")?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = true
        return image
    }

    /// One turn of the sync arrows, clockwise.
    static let spinner: [NSImage] = {
        let base = symbol("arrow.triangle.2.circlepath")
        // square canvas, so no corner is cut off while turning
        let side = ceil(max(base.size.width, base.size.height))
        let size = NSSize(width: side, height: side)
        return (0..<frameCount).map { index in
            let angle = -CGFloat(index) * 360 / CGFloat(frameCount)
            let frame = NSImage(size: size, flipped: false) { rect in
                let transform = NSAffineTransform()
                transform.translateX(by: rect.midX, yBy: rect.midY)
                transform.rotate(byDegrees: angle)
                transform.translateX(by: -rect.midX, yBy: -rect.midY)
                transform.concat()
                base.draw(
                    in: NSRect(
                        x: (side - base.size.width) / 2, y: (side - base.size.height) / 2,
                        width: base.size.width, height: base.size.height))
                return true
            }
            frame.isTemplate = true
            return frame
        }
    }()
}
