import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for multiple in [1, 2] {
        let pixels = size * multiple
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let s = CGFloat(pixels)
        let background = NSBezierPath(roundedRect: NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88), xRadius: s * 0.20, yRadius: s * 0.20)
        NSColor(calibratedRed: 0.04, green: 0.43, blue: 0.43, alpha: 1).setFill(); background.fill()
        NSColor.white.withAlphaComponent(0.24).setStroke()
        for ratio in [0.34, 0.52] {
            let path = NSBezierPath(ovalIn: NSRect(x: s * (0.64 - ratio / 2), y: s * (0.65 - ratio / 2), width: s * ratio, height: s * ratio))
            path.lineWidth = max(1, s * 0.025); path.stroke()
        }
        if let symbol = NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: s * 0.52, weight: .bold)) {
            let rect = NSRect(x: s * 0.21, y: s * 0.13, width: s * 0.48, height: s * 0.61)
            symbol.withSymbolConfiguration(.init(paletteColors: [.white]))?.draw(in: rect)
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = multiple == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
