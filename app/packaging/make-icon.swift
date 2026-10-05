// Generates a 1024×1024 app icon PNG: a gradient rounded square with three
// stacked white "layers" (the SkyStack mark). Best-effort — packaging proceeds
// without it. Usage: swift make-icon.swift <out.png>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let side: CGFloat = 1024

let image = NSImage(size: NSSize(width: side, height: side))
image.lockFocus()

// Gradient rounded-square background.
let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side).insetBy(dx: 64, dy: 64),
                      xRadius: 200, yRadius: 200)
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.27, green: 0.52, blue: 0.98, alpha: 1),
    NSColor(srgbRed: 0.10, green: 0.20, blue: 0.50, alpha: 1),
])!
gradient.draw(in: bg, angle: -90)

// Three stacked layers (bottom dim → top bright) for depth.
let layerW: CGFloat = 540
let layerH: CGFloat = 130
let gap: CGFloat = 40
let totalH = layerH * 3 + gap * 2
let x = (side - layerW) / 2
var y = (side - totalH) / 2
for alpha in [0.55, 0.78, 1.0] {
    let layer = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: layerW, height: layerH),
                             xRadius: 30, yRadius: 30)
    NSColor(white: 1.0, alpha: alpha).setFill()
    layer.fill()
    y += layerH + gap
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("icon render failed\n".utf8))
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: out))
} catch {
    FileHandle.standardError.write(Data("icon write failed: \(error)\n".utf8))
    exit(1)
}
