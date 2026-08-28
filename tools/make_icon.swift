// Regenerates Resources/AppIcon.png. Run: swift tools/make_icon.swift Resources/AppIcon.png
// build_app.sh packs it into AppIcon.icns via sips + iconutil if present.
import AppKit

// A 6m/2m Yagi on a mast, with radiating arcs — legible as a silhouette
// at 16pt and recognisable as a VHF antenna rather than a generic wifi
// glyph, which is what this app is actually about.
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Rounded-rect ground, in the dark slate the app's chrome sits on.
let inset: CGFloat = 44
let bg = CGRect(x: inset, y: inset, width: S - inset*2, height: S - inset*2)
ctx.saveGState()
let path = CGPath(roundedRect: bg, cornerWidth: 200, cornerHeight: 200, transform: nil)
ctx.addPath(path)
ctx.setFillColor(CGColor(red: 0.11, green: 0.13, blue: 0.16, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

let sky = CGColor(red: 0.40, green: 0.72, blue: 1.00, alpha: 1)   // Palette "sky"
let amber = CGColor(red: 0.98, green: 0.66, blue: 0.35, alpha: 1)

// Radiating arcs, upper right — signal leaving the beam.
ctx.setStrokeColor(amber)
ctx.setLineCap(.round)
let origin = CGPoint(x: 690, y: 540)
for (i, r) in [110.0, 172.0, 234.0].enumerated() {
    ctx.setLineWidth(26 - CGFloat(i) * 3)
    ctx.addArc(center: origin, radius: CGFloat(r),
               startAngle: -0.50, endAngle: 0.72, clockwise: false)
    ctx.strokePath()
}

// Mast.
ctx.setStrokeColor(sky)
ctx.setLineWidth(34)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 372, y: 200))
ctx.addLine(to: CGPoint(x: 372, y: 560))
ctx.strokePath()

// Boom, angled slightly up, with five elements shortening toward the
// front — a Yagi reads instantly to any VHF operator.
ctx.saveGState()
ctx.translateBy(x: 372, y: 560)
ctx.rotate(by: -0.30)
ctx.setLineWidth(26)
ctx.move(to: .zero)
ctx.addLine(to: CGPoint(x: 0, y: 300))
ctx.strokePath()

let elements: [(CGFloat, CGFloat)] = [(15, 145), (85, 128), (155, 111), (220, 95), (285, 80)]
ctx.setLineWidth(22)
for (y, half) in elements {
    ctx.move(to: CGPoint(x: -half, y: y))
    ctx.addLine(to: CGPoint(x: half, y: y))
    ctx.strokePath()
}
ctx.restoreGState()

// Guy lines.
ctx.setStrokeColor(sky.copy(alpha: 0.45)!)
ctx.setLineWidth(12)
for x in [CGFloat(220), CGFloat(524)] {
    ctx.move(to: CGPoint(x: 372, y: 500))
    ctx.addLine(to: CGPoint(x: x, y: 210))
    ctx.strokePath()
}

// Ground line.
ctx.setStrokeColor(sky.copy(alpha: 0.7)!)
ctx.setLineWidth(24)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 196, y: 200))
ctx.addLine(to: CGPoint(x: 548, y: 200))
ctx.strokePath()

img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1])")
