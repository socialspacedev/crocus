import AppKit

let S: CGFloat = 1024

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func petal(length L: CGFloat, width Wd: CGFloat) -> NSBezierPath {
    // Base at (0,0), tip at (0,L), pointing up.
    let p = NSBezierPath()
    p.move(to: NSPoint(x: 0, y: 0))
    p.curve(to: NSPoint(x: 0, y: L),
            controlPoint1: NSPoint(x: Wd, y: L * 0.22),
            controlPoint2: NSPoint(x: Wd * 0.45, y: L * 0.96))
    p.curve(to: NSPoint(x: 0, y: 0),
            controlPoint1: NSPoint(x: -Wd * 0.45, y: L * 0.96),
            controlPoint2: NSPoint(x: -Wd, y: L * 0.22))
    p.close()
    return p
}

func transformed(_ path: NSBezierPath, dx: CGFloat, dy: CGFloat, rot: CGFloat) -> NSBezierPath {
    let t = AffineTransform(translationByX: dx, byY: dy)
    var r = AffineTransform(rotationByDegrees: rot)
    let copy = path.copy() as! NSBezierPath
    r.append(t)               // rotate then translate
    var m = AffineTransform(translationByX: dx, byY: dy)
    m.rotate(byDegrees: rot)
    copy.transform(using: m)
    return copy
}

func fillGradient(_ path: NSBezierPath, _ c1: NSColor, _ c2: NSColor, angle: CGFloat = 90) {
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let g = NSGradient(starting: c1, ending: c2)!
    g.draw(in: path.bounds, angle: angle)
    NSGraphicsContext.restoreGraphicsState()
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Tile background (rounded square) with vertical gradient.
let inset: CGFloat = 70
let tile = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: S - inset*2, height: S - inset*2),
                        xRadius: 200, yRadius: 200)
fillGradient(tile, color(0.10, 0.16, 0.12), color(0.04, 0.06, 0.05), angle: 90)

// Soft radial glow behind the bloom (drawn over the whole tile so no hard edge).
NSGraphicsContext.saveGraphicsState()
tile.addClip()
if let glow = NSGradient(colors: [color(0.30, 0.72, 0.46, 0.28), color(0.30, 0.72, 0.46, 0.0)]) {
    glow.draw(in: NSRect(x: inset, y: inset, width: S - inset*2, height: S - inset*2),
              relativeCenterPosition: NSPoint(x: 0, y: 0.05))
}
NSGraphicsContext.restoreGraphicsState()

let baseX: CGFloat = 512
let baseY: CGFloat = 430

// Leaves (behind), slender blades with pale midrib.
for (rot, len) in [(-13.0, 430.0), (12.0, 400.0)] {
    let leaf = petal(length: CGFloat(len), width: 34)
    let lp = transformed(leaf, dx: baseX, dy: baseY - 60, rot: CGFloat(rot))
    fillGradient(lp, color(0.20, 0.50, 0.32), color(0.12, 0.34, 0.21), angle: 90)
}

// Back petals (darker), wide spread.
for rot in [-58.0, 58.0] {
    let bp = transformed(petal(length: 250, width: 92), dx: baseX, dy: baseY, rot: CGFloat(rot))
    fillGradient(bp, color(0.24, 0.56, 0.37), color(0.16, 0.42, 0.27), angle: 90)
}

// Front three petals (the crocus cup).
let frontSpecs: [(CGFloat, CGFloat, CGFloat)] = [(-30, 250, 96), (0, 300, 104), (30, 250, 96)]
for (rot, L, Wd) in frontSpecs {
    let fp = transformed(petal(length: L, width: Wd), dx: baseX, dy: baseY, rot: rot)
    fillGradient(fp, color(0.66, 0.92, 0.74), color(0.34, 0.74, 0.50), angle: 90)
}

NSGraphicsContext.restoreGraphicsState()

let outURL = URL(fileURLWithPath: CommandLine.arguments[1])
try! rep.representation(using: .png, properties: [:])!.write(to: outURL)
print("wrote \(outURL.path)")
