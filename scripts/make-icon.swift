// Draws the app icon and writes a 1024 px master PNG. Run through scripts/make-icon.sh.
import AppKit

let size = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
else {
    fatalError("could not create bitmap")
}
NSGraphicsContext.current = context

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Body: the standard macOS icon shape, 824 pt on a 1024 canvas.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
color(0x15161C).setFill()
bodyPath.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(starting: color(0x30323F), ending: color(0x14151A))!.draw(in: bodyPath, angle: -90)

// Soft glow behind the sliders.
NSGraphicsContext.saveGraphicsState()
bodyPath.addClip()
NSGradient(starting: color(0x4C8DFF, 0.22), ending: color(0x4C8DFF, 0))!
    .draw(in: NSBezierPath(ovalIn: NSRect(x: 162, y: 60, width: 700, height: 700)), relativeCenterPosition: .zero)
NSGraphicsContext.restoreGraphicsState()

// Hairline along the top edge.
NSGraphicsContext.saveGraphicsState()
bodyPath.addClip()
color(0xFFFFFF, 0.10).setStroke()
let edge = NSBezierPath(roundedRect: body.insetBy(dx: 3, dy: 3), xRadius: 183, yRadius: 183)
edge.lineWidth = 6
edge.stroke()
NSGraphicsContext.restoreGraphicsState()

// Three vertical sliders at different levels.
let trackWidth: CGFloat = 46
let trackHeight: CGFloat = 470
let trackBottom: CGFloat = 512 - trackHeight / 2
let knobRadius: CGFloat = 52
let sliders: [(x: CGFloat, level: CGFloat, top: UInt32, bottom: UInt32)] = [
    (342, 0.68, 0x5EE6C8, 0x2FB5A0),
    (512, 0.34, 0x6FB1FF, 0x3D7BF0),
    (682, 0.86, 0xB79CFF, 0x7C5CF0),
]

for slider in sliders {
    let track = NSRect(x: slider.x - trackWidth / 2, y: trackBottom, width: trackWidth, height: trackHeight)
    color(0xFFFFFF, 0.12).setFill()
    NSBezierPath(roundedRect: track, xRadius: trackWidth / 2, yRadius: trackWidth / 2).fill()

    let knobY = trackBottom + trackHeight * slider.level
    let fill = NSRect(x: track.minX, y: track.minY, width: trackWidth, height: knobY - track.minY)
    NSGradient(starting: color(slider.top), ending: color(slider.bottom))!
        .draw(in: NSBezierPath(roundedRect: fill, xRadius: trackWidth / 2, yRadius: trackWidth / 2), angle: -90)

    NSGraphicsContext.saveGraphicsState()
    let knobShadow = NSShadow()
    knobShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    knobShadow.shadowBlurRadius = 18
    knobShadow.shadowOffset = NSSize(width: 0, height: -8)
    knobShadow.set()
    let knob = NSBezierPath(ovalIn: NSRect(
        x: slider.x - knobRadius, y: knobY - knobRadius, width: knobRadius * 2, height: knobRadius * 2))
    color(0xF4F5F8).setFill()
    knob.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: color(0xFFFFFF), ending: color(0xD9DCE4))!.draw(
        in: NSBezierPath(ovalIn: NSRect(
            x: slider.x - knobRadius, y: knobY - knobRadius, width: knobRadius * 2, height: knobRadius * 2)),
        angle: -90)
}

context.flushGraphics()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("could not encode PNG")
}
try png.write(to: URL(fileURLWithPath: output))
