// Draws the app icon: two tables whose wires run through a zip tie.
// Usage: swift scripts/make_icon.swift   (writes every size into Joinery/Assets.xcassets/AppIcon.appiconset)
import AppKit

let canvas: CGFloat = 1024
// Apple's macOS icon grid: an 824-point rounded square, inset 100 points, corner radius 185.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(size: Int) -> Data {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
        let c = NSGraphicsContext.current!.cgContext
        c.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)

        // Body with a soft drop shadow, then a subtle top-to-bottom gradient.
        let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, 0.28))
        c.addPath(shape); c.setFillColor(color(0xFFFFFF)); c.fillPath()
        c.restoreGState()
        c.saveGState()
        c.addPath(shape); c.clip()
        let gradient = CGGradient(colorsSpace: nil, colors: [color(0xFFFFFF), color(0xECEEF2)] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
        // Dot grid, as on the canvas.
        c.setFillColor(color(0x000000, 0.09))
        for x in stride(from: body.minX + 36, to: body.maxX, by: 52) {
            for y in stride(from: body.minY + 36, to: body.maxY, by: 52) { c.fillEllipse(in: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)) }
        }

        let rows: CGFloat = 62, header: CGFloat = 78
        func card(_ frame: CGRect, tint: UInt32) {
            let path = CGPath(roundedRect: frame, cornerWidth: 34, cornerHeight: 34, transform: nil)
            c.saveGState()
            c.setShadow(offset: CGSize(width: 0, height: 10), blur: 26, color: color(0x000000, 0.16))
            c.addPath(path); c.setFillColor(color(0xFFFFFF)); c.fillPath()
            c.restoreGState()
            c.saveGState()
            c.addPath(path); c.clip()
            c.setFillColor(color(tint, 0.2)); c.fill(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: header))
            c.setFillColor(color(0x000000, 0.1)); c.fill(CGRect(x: frame.minX, y: frame.minY + header, width: frame.width, height: 3))
            // Title and column placeholders.
            c.setFillColor(color(tint)); c.fill(CGRect(x: frame.minX + 34, y: frame.minY + 30, width: 92, height: 18))
            c.setFillColor(color(0x000000, 0.16))
            for row in 0..<3 {
                let y = frame.minY + header + CGFloat(row) * rows + rows / 2 - 7
                c.fill(CGRect(x: frame.minX + 34, y: y, width: [104, 76, 92][row], height: 14))
            }
            c.restoreGState()
            c.addPath(path); c.setStrokeColor(color(0x000000, 0.08)); c.setLineWidth(3); c.strokePath()
        }

        let left = CGRect(x: 150, y: 300, width: 226, height: header + 3 * rows + 14)
        let right = CGRect(x: 648, y: 420, width: 226, height: header + 3 * rows + 14)
        card(left, tint: 0x0A84FF)
        card(right, tint: 0xFF9F0A)

        // Three wires, tied in the middle.
        // Halfway between the two tables' middle rows.
        let tie = CGPoint(x: 512, y: (left.minY + right.minY) / 2 + header + 1.5 * rows), spacing: CGFloat = 22
        let wires: [UInt32] = [0x0A84FF, 0xBF5AF2, 0xFF375F]
        for (index, hex) in wires.enumerated() {
            let i = CGFloat(index)
            let start = CGPoint(x: left.maxX, y: left.minY + header + (i + 0.5) * rows)
            let end = CGPoint(x: right.minX, y: right.minY + header + (i + 0.5) * rows)
            let slot = CGPoint(x: tie.x, y: tie.y + (i - 1) * spacing)
            let path = CGMutablePath()
            path.move(to: start)
            path.addCurve(to: slot, control1: CGPoint(x: start.x + 70, y: start.y), control2: CGPoint(x: slot.x - 70, y: slot.y))
            path.addCurve(to: end, control1: CGPoint(x: slot.x + 70, y: slot.y), control2: CGPoint(x: end.x - 70, y: end.y))
            c.addPath(path); c.setStrokeColor(color(0xF4F5F8)); c.setLineWidth(26); c.setLineCap(.round); c.strokePath()
            c.addPath(path); c.setStrokeColor(color(hex)); c.setLineWidth(15); c.strokePath()
            for point in [start, end] {
                c.setFillColor(color(hex)); c.fillEllipse(in: CGRect(x: point.x - 15, y: point.y - 15, width: 30, height: 30))
                c.setStrokeColor(color(0xFFFFFF)); c.setLineWidth(5); c.strokeEllipse(in: CGRect(x: point.x - 15, y: point.y - 15, width: 30, height: 30))
            }
        }
        let band = CGRect(x: tie.x - 13, y: tie.y - spacing - 30, width: 26, height: 2 * spacing + 60)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: 4), blur: 8, color: color(0x000000, 0.25))
        c.addPath(CGPath(roundedRect: band, cornerWidth: 13, cornerHeight: 13, transform: nil))
        c.setFillColor(color(0x8E8E93)); c.fillPath()
        c.restoreGState()
        c.restoreGState()
        return true
    }
    let rep = NSBitmapImageRep(data: image.tiffRepresentation(using: .none, factor: 1)!)!
    return rep.representation(using: .png, properties: [:])!
}

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Joinery/Assets.xcassets/AppIcon.appiconset")
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! render(size: points * scale).write(to: folder.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: folder.appendingPathComponent("Contents.json"))
