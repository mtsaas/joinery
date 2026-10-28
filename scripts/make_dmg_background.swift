// Draws the disk image's window background: an arrow from Joinery to Applications and a line saying what to do.
// The icons sit on it where scripts/release.sh puts them; both use the numbers below.
// Usage: swift scripts/make_dmg_background.swift <out.png> <scale>
import AppKit

let size = CGSize(width: 640, height: 400)
let iconY: CGFloat = 180, appX: CGFloat = 180, applicationsX: CGFloat = 460, iconSize: CGFloat = 128
let out = CommandLine.arguments[1]
let scale = CGFloat(Double(CommandLine.arguments[2]) ?? 1)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
// Finder's coordinates run down from the top; flip to match.
let context = NSGraphicsContext.current!.cgContext
context.translateBy(x: 0, y: size.height)
context.scaleBy(x: 1, y: -1)

NSColor(srgbRed: 0.965, green: 0.961, blue: 0.953, alpha: 1).setFill()
CGRect(origin: .zero, size: size).fill()

// The arrow spans the gap between the icons, with equal space either side.
let gap: CGFloat = 22
let start = appX + iconSize / 2 + gap, end = applicationsX - iconSize / 2 - gap
let head: CGFloat = 9
let arrow = NSBezierPath()
arrow.move(to: CGPoint(x: start, y: iconY))
arrow.line(to: CGPoint(x: end, y: iconY))
arrow.move(to: CGPoint(x: end - head, y: iconY - head))
arrow.line(to: CGPoint(x: end, y: iconY))
arrow.line(to: CGPoint(x: end - head, y: iconY + head))
arrow.lineWidth = 2
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(white: 0, alpha: 0.22).setStroke()
arrow.stroke()

let caption = NSAttributedString(string: "Drag Joinery into Applications", attributes: [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: NSColor(white: 0, alpha: 0.42),
])
let captionSize = caption.size()
// Drawn upright in the flipped context.
context.saveGState()
context.translateBy(x: 0, y: 330 + captionSize.height / 2)
context.scaleBy(x: 1, y: -1)
caption.draw(at: CGPoint(x: (size.width - captionSize.width) / 2, y: 0))
context.restoreGState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(filePath: out))
