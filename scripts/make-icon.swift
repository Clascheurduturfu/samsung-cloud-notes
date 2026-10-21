import AppKit

// Original artwork for this unofficial client; no Samsung asset is bundled.
let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    NSColor(calibratedRed: 0.98, green: 0.28, blue: 0.12, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 50, y: 50, width: 924, height: 924), xRadius: 206, yRadius: 206).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 252, y: 205, width: 510, height: 624), xRadius: 42, yRadius: 42).fill()
    NSColor(calibratedRed: 1, green: 0.80, blue: 0.72, alpha: 1).setFill()
    let fold = NSBezierPath(); fold.move(to: NSPoint(x: 638, y: 829)); fold.line(to: NSPoint(x: 762, y: 705)); fold.line(to: NSPoint(x: 638, y: 705)); fold.close(); fold.fill()
    NSColor(calibratedRed: 0.98, green: 0.28, blue: 0.12, alpha: 1).setStroke()
    for y in [600, 502, 404] {
        let line = NSBezierPath(); line.lineWidth = 27; line.lineCapStyle = .round
        line.move(to: NSPoint(x: 342, y: y)); line.line(to: NSPoint(x: 655, y: y)); line.stroke()
    }
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let png = bitmap.representation(using: .png, properties: [:])!
    if size <= 512 { try png.write(to: URL(fileURLWithPath: output + "/icon_\(size)x\(size).png")) }
    if size >= 32 { try png.write(to: URL(fileURLWithPath: output + "/icon_\(size/2)x\(size/2)@2x.png")) }
}
