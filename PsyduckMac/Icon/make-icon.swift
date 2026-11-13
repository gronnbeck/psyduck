import AppKit
import CoreGraphics
import Foundation

// Draws the psyduck mark — an amber square with ψ (psi, for psyduck) — as a macOS
// app icon, and writes every size the asset catalog expects.
//
// Since Big Sur an app supplies its own icon shape: a rounded square sitting
// inside a transparent canvas, rather than a full-bleed square that the system
// masks. Apple's grid puts an 824pt rounded rect inside a 1024pt canvas with a
// corner radius of 185.4pt. The mark follows that grid, with the design
// system's 1.5px border and 4px hard shadow scaled up to match.
//
//   swift make-icon.swift ../Sources/Assets.xcassets/AppIcon.appiconset

let canvas: CGFloat = 1024
let content: CGFloat = 824
let radius: CGFloat = 185.4

// The design system's 1.5px border on a 30px mark, scaled to 824.
let borderWidth: CGFloat = 1.5 / 30 * content
// And its 4px hard shadow — pulled in a little so it stays inside the canvas.
let shadowOffset: CGFloat = 3.2 / 30 * content

let ink = NSColor(srgbRed: 0x14 / 255, green: 0x11 / 255, blue: 0x0D / 255, alpha: 1)
let amber = NSColor(srgbRed: 0xE6 / 255, green: 0xA3 / 255, blue: 0x00 / 255, alpha: 1)

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon <AppIcon.appiconset directory>\n".utf8))
    exit(2)
}
let outputDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func render(size: CGFloat) -> CGImage {
    let scale = size / canvas
    guard let context = CGContext(
        data: nil,
        width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not create context") }

    context.interpolationQuality = .high
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.scaleBy(x: scale, y: scale)

    // The shadow sits down-right in screen terms; CoreGraphics' y goes up.
    let inset = (canvas - content) / 2
    let frame = CGRect(x: inset, y: inset, width: content, height: content)
        .insetBy(dx: shadowOffset / 2, dy: shadowOffset / 2)
    let shadowFrame = frame.offsetBy(dx: shadowOffset, dy: -shadowOffset)

    context.setFillColor(ink.cgColor)
    context.addPath(CGPath(roundedRect: shadowFrame, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()

    context.setFillColor(amber.cgColor)
    context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()

    context.setStrokeColor(ink.cgColor)
    context.setLineWidth(borderWidth)
    let strokeFrame = frame.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
    context.addPath(CGPath(roundedRect: strokeFrame, cornerWidth: radius - borderWidth / 2,
                           cornerHeight: radius - borderWidth / 2, transform: nil))
    context.strokePath()

    // ψ in Georgia Bold.
    let fontSize = content * 0.62
    let font = NSFont(name: "Georgia-Bold", size: fontSize) ?? NSFont.boldSystemFont(ofSize: fontSize)
    let attributes: [NSAttributedString.Key: Any] = [ .font: font, .foregroundColor: ink ]
    let glyph = NSAttributedString(string: "ψ", attributes: attributes)
    let line = CTLineCreateWithAttributedString(glyph)
    let bounds = CTLineGetImageBounds(line, context)
    let x = frame.midX - bounds.midX
    let y = frame.midY - bounds.midY
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, context)

    guard let image = context.makeImage() else { fatalError("could not render \(size)") }
    return image
}

func write(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("could not write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

struct Spec {
    let size: Int
    let scale: Int
    var filename: String { "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png" }
    var pixels: CGFloat { CGFloat(size * scale) }
}

let specs = [
    Spec(size: 16, scale: 1), Spec(size: 16, scale: 2),
    Spec(size: 32, scale: 1), Spec(size: 32, scale: 2),
    Spec(size: 128, scale: 1), Spec(size: 128, scale: 2),
    Spec(size: 256, scale: 1), Spec(size: 256, scale: 2),
    Spec(size: 512, scale: 1), Spec(size: 512, scale: 2)
]

var images: [String: Any] = [:]
var entries: [[String: String]] = []
for spec in specs {
    write(render(size: spec.pixels), to: outputDir.appendingPathComponent(spec.filename))
    entries.append([
        "filename": spec.filename,
        "idiom": "mac",
        "scale": "\(spec.scale)x",
        "size": "\(spec.size)x\(spec.size)"
    ])
    print("wrote \(spec.filename)")
}

let contents: [String: Any] = [
    "images": entries,
    "info": [ "author": "xcode", "version": 1 ]
]
let json = try JSONSerialization.data(withJSONObject: contents, options: [ .prettyPrinted, .sortedKeys ])
try json.write(to: outputDir.appendingPathComponent("Contents.json"))
print("wrote Contents.json")
