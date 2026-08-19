import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Render a 1024x1024 macOS app icon: charcoal rounded tile + run-green pulse waveform.
// Usage: swift scripts/draw-app-icon.swift [output.png]  (defaults to ./AgentPulse-1024.png)
let S: CGFloat = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: Int(S),
    height: Int(S),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("ctx") }

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r/255, g/255, b/255, a])!
}

// macOS Big Sur+ icon: content inset with rounded superellipse-ish rect.
// Apple grid: 1024 canvas, icon body ~824 centered (100 margin each side), corner radius ~185.
let margin: CGFloat = 100
let bodyRect = CGRect(x: margin, y: margin, width: S - 2*margin, height: S - 2*margin)
let corner: CGFloat = 185

func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// --- Drop shadow under the tile ---
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(0,0,0,0.35))
ctx.addPath(roundedPath(bodyRect, corner))
ctx.setFillColor(rgb(20, 22, 30))
ctx.fillPath()
ctx.restoreGState()

// --- Tile background: near-black charcoal, subtle top-lit vertical gradient (no blue/purple) ---
ctx.saveGState()
ctx.addPath(roundedPath(bodyRect, corner))
ctx.clip()
let bgColors = [rgb(38, 40, 43), rgb(26, 27, 30), rgb(15, 16, 18)] as CFArray
let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(bgGrad,
    start: CGPoint(x: bodyRect.minX, y: bodyRect.maxY),
    end: CGPoint(x: bodyRect.minX, y: bodyRect.minY),
    options: [])

// Subtle green ambient glow behind the waveform (run-green signal)
let glowColors = [rgb(34, 197, 94, 0.20), rgb(34, 197, 94, 0)] as CFArray
let glowGrad = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0, 1])!
ctx.drawRadialGradient(glowGrad,
    startCenter: CGPoint(x: S*0.5, y: S*0.5), startRadius: 0,
    endCenter: CGPoint(x: S*0.5, y: S*0.5), endRadius: bodyRect.width*0.55,
    options: [])
ctx.restoreGState()

// --- Inner top edge sheen (glossy rim) ---
ctx.saveGState()
ctx.addPath(roundedPath(bodyRect, corner))
ctx.clip()
let rimColors = [rgb(255,255,255,0.22), rgb(255,255,255,0)] as CFArray
let rimGrad = CGGradient(colorsSpace: colorSpace, colors: rimColors, locations: [0,1])!
ctx.drawLinearGradient(rimGrad,
    start: CGPoint(x: bodyRect.minX, y: bodyRect.maxY),
    end: CGPoint(x: bodyRect.minX, y: bodyRect.maxY - 220),
    options: [])
ctx.restoreGState()

// --- Pulse / TPS waveform ---
// Build a heartbeat-like ECG pulse across the middle.
func wavePoints() -> [CGPoint] {
    let baseY = S * 0.5
    let left = bodyRect.minX + 120
    let right = bodyRect.maxX - 120
    let amp: CGFloat = 150
    // control points describing a flat line -> spike -> flat, ECG style
    // normalized x in [0,1] mapped to left..right, y offset in amplitude units
    let nodes: [(CGFloat, CGFloat)] = [
        (0.00,  0.00),
        (0.22,  0.00),
        (0.30,  0.18),
        (0.37, -0.30),
        (0.46,  1.00),   // tall spike
        (0.54, -0.62),
        (0.62,  0.12),
        (0.70,  0.00),
        (1.00,  0.00),
    ]
    return nodes.map { (nx, ny) in
        CGPoint(x: left + (right-left)*nx, y: baseY + amp*ny)
    }
}
let pts = wavePoints()

// Smooth path through points (Catmull-Rom -> bezier)
func smoothPath(_ p: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    guard p.count > 1 else { return path }
    path.move(to: p[0])
    for i in 0..<(p.count - 1) {
        let p0 = p[max(i-1, 0)]
        let p1 = p[i]
        let p2 = p[i+1]
        let p3 = p[min(i+2, p.count-1)]
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x)/6, y: p1.y + (p2.y - p0.y)/6)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x)/6, y: p2.y - (p3.y - p1.y)/6)
        path.addCurve(to: p2, control1: c1, control2: c2)
    }
    return path
}
let wavePath = smoothPath(pts)

// Glow pass (thick, blurred, run-green accent)
ctx.saveGState()
ctx.addPath(wavePath)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setLineWidth(46)
ctx.setStrokeColor(rgb(34, 197, 94, 0.50))
ctx.setShadow(offset: .zero, blur: 55, color: rgb(52, 211, 153, 0.9))
ctx.strokePath()
ctx.restoreGState()

// Core stroke with gradient along the line (emerald -> green -> lime, no blue/purple)
ctx.saveGState()
let stroked = wavePath.copy(strokingWithWidth: 30, lineCap: .round, lineJoin: .round, miterLimit: 10)
ctx.addPath(stroked)
ctx.clip()
let lineColors = [rgb(52, 211, 153), rgb(34, 197, 94), rgb(163, 230, 53)] as CFArray
let lineGrad = CGGradient(colorsSpace: colorSpace, colors: lineColors, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(lineGrad,
    start: CGPoint(x: bodyRect.minX, y: 0),
    end: CGPoint(x: bodyRect.maxX, y: 0),
    options: [])
ctx.restoreGState()

// Bright dot at the peak (the "live" sampling point) — warm amber accent to pop against green
let peak = pts[4]
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 44, color: rgb(249, 168, 60, 0.95))
ctx.setFillColor(rgb(253, 224, 130, 1))
ctx.fillEllipse(in: CGRect(x: peak.x-26, y: peak.y-26, width: 52, height: 52))
ctx.setShadow(offset: .zero, blur: 0, color: rgb(0,0,0,0))
ctx.setFillColor(rgb(255, 255, 255, 1))
ctx.fillEllipse(in: CGRect(x: peak.x-13, y: peak.y-13, width: 26, height: 26))
ctx.restoreGState()

// --- Export PNG ---
guard let image = ctx.makeImage() else { fatalError("image") }
let outURL = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AgentPulse-1024.png")
guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("dest") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("finalize") }
print("wrote \(outURL.path)")
