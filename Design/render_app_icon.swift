import AppKit

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

NSColor(calibratedRed: 0.067, green: 0.067, blue: 0.059, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

func drawArc(color: NSColor, from startAngle: CGFloat, to endAngle: CGFloat) {
    let path = NSBezierPath()
    path.appendArc(
        withCenter: NSPoint(x: 512, y: 512),
        radius: 275,
        startAngle: startAngle,
        endAngle: endAngle,
        clockwise: false
    )
    path.lineWidth = 94
    path.lineCapStyle = .round
    color.setStroke()
    path.stroke()
}

let lime = NSColor(calibratedRed: 0.86, green: 1.0, blue: 0.24, alpha: 1)
let coral = NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.31, alpha: 1)
drawArc(color: lime, from: 24, to: 156)
drawArc(color: coral, from: 204, to: 336)

func drawArrow(at point: NSPoint, angle: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: -72, y: -50))
    path.line(to: NSPoint(x: 72, y: 0))
    path.line(to: NSPoint(x: -72, y: 50))
    path.close()

    var transform = AffineTransform()
    transform.translate(x: point.x, y: point.y)
    transform.rotate(byDegrees: angle)
    path.transform(using: transform)
    color.setFill()
    path.fill()
}

drawArrow(at: NSPoint(x: 748, y: 650), angle: -38, color: lime)
drawArrow(at: NSPoint(x: 276, y: 374), angle: 142, color: coral)

let play = NSBezierPath()
play.move(to: NSPoint(x: 452, y: 388))
play.line(to: NSPoint(x: 668, y: 512))
play.line(to: NSPoint(x: 452, y: 636))
play.close()
NSColor.white.setFill()
play.fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not render app icon")
}

let destination = URL(fileURLWithPath: "BandLoop/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try png.write(to: destination)
