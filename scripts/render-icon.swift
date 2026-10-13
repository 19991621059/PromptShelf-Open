import AppKit
let destination = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(calibratedRed: 0.05, green: 0.43, blue: 0.42, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 210, yRadius: 210).fill()
NSColor.white.withAlphaComponent(0.65).setStroke()
let line = NSBezierPath(); line.move(to: NSPoint(x: 288, y: 310)); line.line(to: NSPoint(x: 288, y: 718)); line.lineWidth = 24; line.stroke()
for (y, width) in [(310.0, 310.0), (514.0, 380.0), (718.0, 255.0)] {
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 248, y: y - 40, width: 80, height: 80)).fill()
    NSBezierPath(roundedRect: NSRect(x: 398, y: y - 20, width: width, height: 40), xRadius: 20, yRadius: 20).fill()
}
image.unlockFocus()
let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: destination))
