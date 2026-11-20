// Renders the app icon: a clock with an arrow turning back in time, in the colours of
// Proxmox (orange #E57000 on charcoal). Writes Resources/AppIcon.icns and
// Resources/AppIcon.png (1024 px preview).
//
//     swift scripts/make-icon.swift
import AppKit

let orange = NSColor(srgbRed: 0xE5 / 255, green: 0x70 / 255, blue: 0x00 / 255, alpha: 1)
let lightOrange = NSColor(srgbRed: 0xFF / 255, green: 0x9A / 255, blue: 0x2E / 255, alpha: 1)
let charcoalTop = NSColor(srgbRed: 0x3A / 255, green: 0x3A / 255, blue: 0x3C / 255, alpha: 1)
let charcoalBottom = NSColor(srgbRed: 0x16 / 255, green: 0x16 / 255, blue: 0x18 / 255, alpha: 1)
let faceTop = NSColor(white: 0.20, alpha: 1)
let faceBottom = NSColor(white: 0.10, alpha: 1)

/// Draws the icon on a 1024 × 1024 canvas.
func draw(in ctx: CGContext) {
    let center = CGPoint(x: 512, y: 512)

    // macOS icon grid: 824 px rounded square with a soft shadow
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor(white: 0, alpha: 0.35).cgColor)
    ctx.addPath(tilePath)
    ctx.setFillColor(charcoalBottom.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let background = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [charcoalTop.cgColor, charcoalBottom.cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // the arrow: an orange arc almost all the way round, turning counter-clockwise
    let arcRadius: CGFloat = 300
    let arcWidth: CGFloat = 54
    let gapStart: CGFloat = 62  // degrees, where the arrow head points into the gap
    let gapEnd: CGFloat = 112
    let arc = CGMutablePath()
    // from the tail (gapEnd) counter-clockwise round to the head (gapStart + 360)
    arc.addArc(
        center: center, radius: arcRadius, startAngle: gapEnd * .pi / 180,
        endAngle: (gapStart + 360 - 20) * .pi / 180, clockwise: false)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor(white: 0, alpha: 0.45).cgColor)
    ctx.setLineCap(.round)
    ctx.setLineWidth(arcWidth)
    ctx.addPath(arc)
    ctx.replacePathWithStrokedPath()
    // arrow head at the end of the arc, pointing counter-clockwise (towards the gap)
    let headAngle = (gapStart + 360 - 22) * CGFloat.pi / 180
    let tangent = CGPoint(x: -sin(headAngle), y: cos(headAngle))  // counter-clockwise direction
    let radial = CGPoint(x: cos(headAngle), y: sin(headAngle))
    let base = CGPoint(x: center.x + arcRadius * radial.x, y: center.y + arcRadius * radial.y)
    let headLength: CGFloat = 120
    let headWidth: CGFloat = 70
    let tip = CGPoint(x: base.x + tangent.x * headLength, y: base.y + tangent.y * headLength)
    let outer = CGPoint(x: base.x + radial.x * headWidth, y: base.y + radial.y * headWidth)
    let inner = CGPoint(x: base.x - radial.x * headWidth, y: base.y - radial.y * headWidth)
    ctx.move(to: tip)
    ctx.addLine(to: outer)
    ctx.addLine(to: inner)
    ctx.closePath()
    ctx.clip(using: .winding)
    let arrowGradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [lightOrange.cgColor, orange.cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(arrowGradient, start: CGPoint(x: 512, y: 860), end: CGPoint(x: 512, y: 160), options: [])
    ctx.restoreGState()

    // clock face
    let faceRadius: CGFloat = 228
    let face = CGRect(x: center.x - faceRadius, y: center.y - faceRadius, width: 2 * faceRadius, height: 2 * faceRadius)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: NSColor(white: 0, alpha: 0.5).cgColor)
    ctx.addEllipse(in: face)
    ctx.setFillColor(faceBottom.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: face)
    ctx.clip()
    let faceGradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [faceTop.cgColor, faceBottom.cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(faceGradient, start: CGPoint(x: 512, y: face.maxY), end: CGPoint(x: 512, y: face.minY), options: [])
    ctx.restoreGState()
    ctx.addEllipse(in: face.insetBy(dx: 6, dy: 6))
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.12).cgColor)
    ctx.setLineWidth(4)
    ctx.strokePath()

    // ticks: long and orange every 3 hours, short and white otherwise
    ctx.setLineCap(.round)
    for hour in 0..<12 {
        let angle = CGFloat(hour) * .pi / 6
        let major = hour % 3 == 0
        let outerR = faceRadius - 30
        let innerR = outerR - (major ? 46 : 26)
        ctx.move(to: CGPoint(x: center.x + innerR * sin(angle), y: center.y + innerR * cos(angle)))
        ctx.addLine(to: CGPoint(x: center.x + outerR * sin(angle), y: center.y + outerR * cos(angle)))
        ctx.setStrokeColor(major ? orange.cgColor : NSColor(white: 0.85, alpha: 1).cgColor)
        ctx.setLineWidth(major ? 18 : 10)
        ctx.strokePath()
    }

    // hands at ten past ten, white, with an orange hub
    func hand(angleDegrees: CGFloat, length: CGFloat, width: CGFloat) {
        let angle = angleDegrees * .pi / 180
        ctx.move(to: center)
        ctx.addLine(to: CGPoint(x: center.x + length * sin(angle), y: center.y + length * cos(angle)))
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(width)
        ctx.strokePath()
    }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 8, color: NSColor(white: 0, alpha: 0.5).cgColor)
    hand(angleDegrees: -60, length: 112, width: 26)  // hour hand towards 10
    hand(angleDegrees: 60, length: 160, width: 18)  // minute hand towards 2
    ctx.restoreGState()
    ctx.addEllipse(in: CGRect(x: center.x - 24, y: center.y - 24, width: 48, height: 48))
    ctx.setFillColor(orange.cgColor)
    ctx.fillPath()
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = graphics.cgContext
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    ctx.interpolationQuality = .high
    draw(in: ctx)
    graphics.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appending(path: "Resources")
let iconset = fm.temporaryDirectory.appending(path: "AppIcon-\(getpid()).iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try render(size: points).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try render(size: points * 2).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}
try render(size: 1024).write(to: resources.appending(path: "AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appending(path: "AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { exit(1) }
print("Resources/AppIcon.icns")
