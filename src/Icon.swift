import Cocoa

// Zeichnet das App-Symbol: 声 auf hellem Grund, darunter drei Pegelbalken in den Markenfarben.

let groesse: CGFloat = 1024
let bild = NSImage(size: NSSize(width: groesse, height: groesse))
bild.lockFocus()

let rand: CGFloat = 92
let flaeche = NSRect(x: rand, y: rand, width: groesse - 2 * rand, height: groesse - 2 * rand)
let form = NSBezierPath(roundedRect: flaeche, xRadius: 190, yRadius: 190)
NSColor(srgbRed: 0xF7 / 255.0, green: 0xF9 / 255.0, blue: 0xFC / 255.0, alpha: 1).setFill()
form.fill()
NSColor(srgbRed: 0xE2 / 255.0, green: 0xE8 / 255.0, blue: 0xF0 / 255.0, alpha: 1).setStroke()
form.lineWidth = 10
form.stroke()

let schrift = NSFont(name: "Hiragino Mincho ProN W6", size: 460) ?? NSFont.systemFont(ofSize: 460, weight: .bold)
let attr: [NSAttributedString.Key: Any] = [
    .font: schrift,
    .foregroundColor: NSColor(srgbRed: 0x0D / 255.0, green: 0x11 / 255.0, blue: 0x17 / 255.0, alpha: 1),
]
let zeichen = "声" as NSString
let g = zeichen.size(withAttributes: attr)
zeichen.draw(at: NSPoint(x: (groesse - g.width) / 2, y: 330), withAttributes: attr)

let farben: [NSColor] = [
    NSColor(srgbRed: 0x22 / 255.0, green: 0xD3 / 255.0, blue: 0xEE / 255.0, alpha: 1),
    NSColor(srgbRed: 0x25 / 255.0, green: 0x63 / 255.0, blue: 0xEB / 255.0, alpha: 1),
    NSColor(srgbRed: 0xEF / 255.0, green: 0x48 / 255.0, blue: 0x61 / 255.0, alpha: 1),
]
let hoehen: [CGFloat] = [70, 130, 90]
let breite: CGFloat = 54, abstand: CGFloat = 36
let gesamt = 3 * breite + 2 * abstand
for i in 0..<3 {
    let x = (groesse - gesamt) / 2 + CGFloat(i) * (breite + abstand)
    let h = hoehen[i]
    farben[i].setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: 250 - h / 2, width: breite, height: h), xRadius: 27, yRadius: 27).fill()
}

bild.unlockFocus()
let tiff = bild.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
