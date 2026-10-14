import AppKit

// Die kleine Anzeige unten in der Bildschirmmitte, solange diktiert wird (wie bei Wispr).

final class Pille {
    enum Zustand: Equatable { case aus, aufnahme, freihaendig, verarbeite, fertig, hinweis(String) }

    private let panel: NSPanel
    private let ansicht = PillenAnsicht()
    private var timer: Timer?
    var pegelQuelle: () -> Float = { 0 }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 132, height: 34),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = ansicht
    }

    func zeigen(_ z: Zustand) {
        ansicht.zustand = z
        if z == .aus {
            timer?.invalidate()
            timer = nil
            panel.orderOut(nil)
            return
        }
        var breite: CGFloat = 132
        if case .hinweis(let t) = z {
            breite = min(420, max(160, (t as NSString).size(withAttributes: [.font: PillenAnsicht.schrift]).width + 44))
        }
        if let schirm = NSScreen.main {
            let f = schirm.visibleFrame
            panel.setFrame(NSRect(x: f.midX - breite / 2, y: f.minY + 18, width: breite, height: 34), display: true)
        }
        panel.orderFrontRegardless()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.ansicht.schieben(self.pegelQuelle())
            }
        }
        switch z {
        case .fertig:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                if self?.ansicht.zustand == .fertig { self?.zeigen(.aus) }
            }
        case .hinweis:
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                if case .hinweis = self?.ansicht.zustand { self?.zeigen(.aus) }
            }
        default: break
        }
    }
}

final class PillenAnsicht: NSView {
    static let schrift = NSFont.systemFont(ofSize: 12, weight: .medium)
    var zustand: Pille.Zustand = .aus { didSet { needsDisplay = true } }
    private var verlauf = [Float](repeating: 0, count: 18)
    private var phase: CGFloat = 0

    private let blau = NSColor(srgbRed: 0x25 / 255.0, green: 0x63 / 255.0, blue: 0xEB / 255.0, alpha: 1)
    private let coral = NSColor(srgbRed: 0xC4 / 255.0, green: 0x2A / 255.0, blue: 0x45 / 255.0, alpha: 1)
    private let linie = NSColor(srgbRed: 0xE2 / 255.0, green: 0xE8 / 255.0, blue: 0xF0 / 255.0, alpha: 1)
    private let tinte = NSColor(srgbRed: 0x1E / 255.0, green: 0x29 / 255.0, blue: 0x3B / 255.0, alpha: 1)
    private let grau = NSColor(srgbRed: 0x94 / 255.0, green: 0xA3 / 255.0, blue: 0xB8 / 255.0, alpha: 1)

    func schieben(_ p: Float) {
        verlauf.removeFirst()
        verlauf.append(p)
        phase += 0.18
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let form = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor.white.setFill()
        form.fill()
        linie.setStroke()
        form.lineWidth = 1
        form.stroke()

        switch zustand {
        case .aufnahme, .freihaendig:
            // Punkt links: Blau = halten, Coral = freihändig (läuft weiter ohne Taste).
            (zustand == .freihaendig ? coral : blau).setFill()
            NSBezierPath(ovalIn: NSRect(x: 14, y: r.midY - 3.5, width: 7, height: 7)).fill()
            let start: CGFloat = 30, abstand: CGFloat = 5
            blau.setFill()
            for (i, p) in verlauf.enumerated() {
                let h = max(3, CGFloat(p) * (r.height - 12))
                let x = start + CGFloat(i) * abstand
                NSBezierPath(roundedRect: NSRect(x: x, y: r.midY - h / 2, width: 3, height: h), xRadius: 1.5, yRadius: 1.5).fill()
            }
        case .verarbeite:
            for i in 0..<3 {
                let a = 0.35 + 0.65 * max(0, sin(phase - CGFloat(i) * 0.7))
                blau.withAlphaComponent(a).setFill()
                NSBezierPath(ovalIn: NSRect(x: r.midX - 16 + CGFloat(i) * 13, y: r.midY - 3.5, width: 7, height: 7)).fill()
            }
        case .fertig:
            let haken = NSBezierPath()
            haken.move(to: NSPoint(x: r.midX - 7, y: r.midY))
            haken.line(to: NSPoint(x: r.midX - 2, y: r.midY - 5))
            haken.line(to: NSPoint(x: r.midX + 8, y: r.midY + 5))
            haken.lineWidth = 2.2
            haken.lineCapStyle = .round
            blau.setStroke()
            haken.stroke()
        case .hinweis(let t):
            let attr: [NSAttributedString.Key: Any] = [.font: PillenAnsicht.schrift, .foregroundColor: tinte]
            let g = (t as NSString).size(withAttributes: attr)
            (t as NSString).draw(at: NSPoint(x: r.midX - g.width / 2, y: r.midY - g.height / 2), withAttributes: attr)
        case .aus:
            break
        }
    }
}
