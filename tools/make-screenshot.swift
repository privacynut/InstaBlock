// App Store screenshot composer: gradient backdrop, two-line headline
// (second line in the Instagram gradient), device screenshot with rounded
// corners + shadow bleeding off the bottom.
//
// usage: swift make-screenshot.swift <W> <H> <in.png> <out.png> "Line one" "Line two"
import AppKit
import CoreText

let args = CommandLine.arguments
let W = CGFloat(Int(args[1])!), H = CGFloat(Int(args[2])!)
let inputPath = args[3], outputPath = args[4]
let line1 = args[5], line2 = args[6]

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a])!
}
let ig = [0x405DE6, 0x833AB4, 0xC13584, 0xE1306C, 0xFD1D1D, 0xF77737, 0xFCAF45].map { color(UInt32($0)) }

let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                    space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// ---- backdrop: soft vertical wash + two blurred gradient blobs
let wash = CGGradient(colorsSpace: srgb, colors: [color(0xFFF4F8), color(0xF4F2FF)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(wash, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
func blob(center: CGPoint, radius: CGFloat, colors: [CGColor], alpha: CGFloat) {
    ctx.saveGState()
    ctx.setAlpha(alpha)
    let g = CGGradient(colorsSpace: srgb, colors: (colors + [color(0xFFFFFF, 0)]) as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    ctx.restoreGState()
}
blob(center: CGPoint(x: W * 0.92, y: H * 0.86), radius: W * 0.75, colors: [ig[5], ig[3]], alpha: 0.35)
blob(center: CGPoint(x: W * 0.05, y: H * 0.30), radius: W * 0.80, colors: [ig[0], ig[1]], alpha: 0.30)

// ---- device screenshot with rounded corners and shadow, bleeding off the bottom
let image = NSImage(contentsOfFile: inputPath)!
var rect = CGRect(origin: .zero, size: image.size)
let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
let shotW = W * 0.82
let shotH = shotW * CGFloat(cg.height) / CGFloat(cg.width)
let shotX = (W - shotW) / 2
let shotTop = H * (H / W > 1.6 ? 0.245 : 0.235)   // taller (phone) vs squarer (iPad) canvases
let shotY = H - shotTop - shotH                       // CG origin is bottom-left; may be negative (bleed)
let shotRect = CGRect(x: shotX, y: shotY, width: shotW, height: shotH)
let radius = shotW * (H / W > 1.6 ? 0.11 : 0.045)
let path = CGPath(roundedRect: shotRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -W * 0.02), blur: W * 0.09, color: color(0x3A1F4B, 0.35))
ctx.setFillColor(color(0xFFFFFF))
ctx.addPath(path); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(path); ctx.clip()
ctx.draw(cg, in: shotRect)
ctx.restoreGState()
// thin bezel line
ctx.saveGState()
ctx.addPath(path); ctx.setStrokeColor(color(0x000000, 0.12)); ctx.setLineWidth(W * 0.004); ctx.strokePath()
ctx.restoreGState()

// ---- headline (Core Text; second line filled with the gradient)
func roundedFont(_ size: CGFloat) -> CTFont {
    let base = NSFont.systemFont(ofSize: size, weight: .heavy)
    let desc = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
    return NSFont(descriptor: desc, size: size) ?? base
}
let fontSize = W * (H / W > 1.6 ? 0.078 : 0.062)
let font = roundedFont(fontSize)

func drawLine(_ text: String, y: CGFloat, gradient: Bool) {
    let attr = NSAttributedString(string: text, attributes: [
        .font: font, .foregroundColor: NSColor(cgColor: color(0x1C1C1E))!,
    ])
    let line = CTLineCreateWithAttributedString(attr)
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    let x = (W - CGFloat(width)) / 2
    ctx.saveGState()
    ctx.textPosition = CGPoint(x: x, y: y)
    if gradient {
        ctx.setTextDrawingMode(.clip)
        CTLineDraw(line, ctx)
        let g = CGGradient(colorsSpace: srgb, colors: [ig[1], ig[3], ig[5]] as CFArray, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: x, y: y), end: CGPoint(x: x + CGFloat(width), y: y + fontSize), options: [])
    } else {
        CTLineDraw(line, ctx)
    }
    ctx.restoreGState()
}
let lineGap = fontSize * 1.18
let headlineBaseline = H - H * 0.085 - fontSize
drawLine(line1, y: headlineBaseline, gradient: false)
drawLine(line2, y: headlineBaseline - lineGap, gradient: true)

// ---- save
let out = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: out)
rep.size = NSSize(width: W, height: H)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath) \(Int(W))x\(Int(H))")
