// Draws the Lamplight app icon (a lamp shining on an open book) as clean
// vector shapes and writes a 1024×1024 PNG with no transparency.
//
//   swift ios/Scripts/make-icon.swift ios/ABPlayer/Assets.xcassets/AppIcon.appiconset/icon-1024.png
//
// With --mark it draws only the lamp, its light and the book on a transparent
// background, cropped to the drawing (the library title's mark):
//
//   swift ios/Scripts/make-icon.swift --mark ios/ABPlayer/Assets.xcassets/LamplightMark.imageset/mark.png

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let args = Array(CommandLine.arguments.dropFirst())
let markOnly = args.contains("--mark")
let out = args.first { $0 != "--mark" } ?? (markOnly ? "mark.png" : "icon-1024.png")
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: (markOnly ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)!
// Work in a top-left origin, like the original artwork.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

// Paper background, a touch warmer where the light falls.
if !markOnly {
    ctx.setFillColor(rgb(0xEAE3D3))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.drawRadialGradient(gradient([(0, rgb(0xF6EDCF, 1)), (1, rgb(0xEAE3D3, 0))]),
                           startCenter: CGPoint(x: 512, y: 620), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 620), endRadius: 470, options: [])
}

// The beam: a soft-edged cone from the shade down over the book. It's drawn as
// blurred shadows of the cone (shapes far off-canvas, shadows offset back), so
// its edges fade like light instead of ending in a hard line.
let spine = CGPoint(x: 512, y: 872)
func cone(_ spread: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 400, y: 350))
    p.addLine(to: CGPoint(x: 624, y: 350))
    p.addLine(to: CGPoint(x: 880 + spread, y: 660))
    p.addQuadCurve(to: CGPoint(x: 144 - spread, y: 660), control: CGPoint(x: 512, y: 960 + spread))
    p.closeSubpath()
    return p
}
/// Light only comes out from under the shade: a wedge widening from its rim.
func clipBelowShade() {
    let wedge = CGMutablePath()
    wedge.addLines(between: [CGPoint(x: 346, y: 352), CGPoint(x: 678, y: 352), CGPoint(x: 1400, y: 1060), CGPoint(x: -376, y: 1060)])
    wedge.closeSubpath()
    ctx.addPath(wedge)
    ctx.clip()
}

func softFill(_ path: CGPath, _ color: CGColor, blur: CGFloat) {
    ctx.saveGState()
    clipBelowShade()
    // y is flipped in this context, so the shadow offset's y is flipped too.
    ctx.setShadow(offset: CGSize(width: 3000, height: 0), blur: blur, color: color)
    ctx.translateBy(x: -3000, y: 0)
    ctx.addPath(path)
    ctx.setFillColor(rgb(0x000000))
    ctx.fillPath()
    ctx.restoreGState()
}
softFill(cone(40), rgb(0xF7DC74, 0.55), blur: 90)
softFill(cone(-30), rgb(0xF6D654, 0.75), blur: 60)
// bright core just under the shade, fading down the beam
ctx.saveGState()
clipBelowShade()
ctx.drawRadialGradient(gradient([(0, rgb(0xFFF8E2, 1)), (0.25, rgb(0xFCE9A0, 0.85)), (0.7, rgb(0xF6D85E, 0.25)), (1, rgb(0xF6D85E, 0))]),
                       startCenter: CGPoint(x: 512, y: 360), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 420), endRadius: 330, options: [])
ctx.restoreGState()

// Lamp shade: a trapezoid with softly rounded corners and a darker rim.
let shade = CGMutablePath()
let tl = CGPoint(x: 452, y: 128), tr = CGPoint(x: 572, y: 128)
let br = CGPoint(x: 680, y: 356), bl = CGPoint(x: 344, y: 356)
shade.move(to: CGPoint(x: tl.x + 10, y: tl.y))
shade.addLine(to: CGPoint(x: tr.x - 10, y: tr.y))
shade.addQuadCurve(to: CGPoint(x: tr.x + 4, y: tr.y + 9), control: tr)
shade.addLine(to: CGPoint(x: br.x - 4, y: br.y - 12))
shade.addQuadCurve(to: CGPoint(x: br.x - 18, y: br.y), control: br)
shade.addLine(to: CGPoint(x: bl.x + 18, y: bl.y))
shade.addQuadCurve(to: CGPoint(x: bl.x + 4, y: bl.y - 12), control: bl)
shade.addLine(to: CGPoint(x: tl.x - 4, y: tl.y + 9))
shade.addQuadCurve(to: CGPoint(x: tl.x + 10, y: tl.y), control: tl)
shade.closeSubpath()
ctx.saveGState()
ctx.addPath(shade)
ctx.clip()
ctx.drawLinearGradient(gradient([(0, rgb(0xA89887)), (0.5, rgb(0xBCAD9C)), (1, rgb(0xA49482))]),
                       start: CGPoint(x: 344, y: 0), end: CGPoint(x: 680, y: 0), options: [])
// light catching the lower rim
ctx.drawLinearGradient(gradient([(0, rgb(0xFFF1C2, 0)), (1, rgb(0xFFF1C2, 0.35))]),
                       start: CGPoint(x: 0, y: 300), end: CGPoint(x: 0, y: 356), options: [])
ctx.restoreGState()

// Pages: three fanned pages a side, each a curved blade from the spine out to a
// cut edge, darker at the spine and catching the light at the edges.
struct Page { let top: CGPoint; let bottom: CGPoint; let upper: CGPoint; let lower: CGPoint }
let left: [Page] = [
    Page(top: CGPoint(x: 194, y: 556), bottom: CGPoint(x: 208, y: 628), upper: CGPoint(x: 410, y: 640), lower: CGPoint(x: 392, y: 700)),
    Page(top: CGPoint(x: 140, y: 622), bottom: CGPoint(x: 160, y: 692), upper: CGPoint(x: 370, y: 690), lower: CGPoint(x: 360, y: 750)),
    Page(top: CGPoint(x: 104, y: 708), bottom: CGPoint(x: 136, y: 768), upper: CGPoint(x: 330, y: 740), lower: CGPoint(x: 336, y: 800)),
]

func blade(_ p: Page, mirrored: Bool) -> CGPath {
    func m(_ q: CGPoint) -> CGPoint { mirrored ? CGPoint(x: 2 * spine.x - q.x, y: q.y) : q }
    let path = CGMutablePath()
    path.move(to: spine)
    path.addQuadCurve(to: m(p.top), control: m(p.upper))
    path.addLine(to: m(p.bottom))
    path.addQuadCurve(to: spine, control: m(p.lower))
    path.closeSubpath()
    return path
}

for mirrored in [false, true] {
    for (i, page) in left.enumerated() {
        let path = blade(page, mirrored: mirrored)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let outer = mirrored ? CGPoint(x: 2 * spine.x - page.top.x, y: page.top.y) : page.top
        let shadeOf = [0x6E6A5E, 0x64615A, 0x5A5852][i]
        ctx.drawLinearGradient(gradient([(0, rgb(UInt32(shadeOf))), (0.55, rgb(0x6F6A55)), (1, rgb(0x8E8456))]),
                               start: outer, end: spine, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
        // a fine light edge along the top of each page
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(rgb(0xFFF4CF, 0.22))
        ctx.setLineWidth(2)
        ctx.strokePath()
        ctx.restoreGState()
    }
}

var image = ctx.makeImage()!
if markOnly { image = image.cropping(to: CGRect(x: 60, y: 120, width: 904, height: 790))! }
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("Wrote \(out)")
