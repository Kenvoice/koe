import AppKit
import ApplicationServices

// Das Tastenkürzel fürs Diktat:
// - gedrückt halten = sprechen, loslassen = einfügen
// - zweimal kurz tippen = freihändig, nochmal tippen = einfügen
// - Esc während der Aufnahme = verwerfen
// Wird die Taste mit einer anderen Taste kombiniert (rechte ⌥ + L für @), ist es kein Diktat.

final class Taste {
    enum Ereignis { case start, stopp, verwerfen, freihaendig }

    var art = "rechte-option"
    var melden: (Ereignis) -> Void = { _ in }

    private var monitore: [Any] = []
    private var gedrueckt = false
    private var druckZeit = Date.distantPast
    private var letzterTipp = Date.distantPast
    private var aktiv = false        // eine Aufnahme läuft
    private var freihaendig = false
    private var kombiniert = false
    private var tippWarten: DispatchWorkItem?

    private let haltenAb: TimeInterval = 0.28
    private let doppelFenster: TimeInterval = 0.42

    private var tastenCode: UInt16 {
        switch art {
        case "fn": return 63
        case "rechte-befehl": return 54
        default: return 61
        }
    }

    private var flagge: NSEvent.ModifierFlags {
        switch art {
        case "fn": return .function
        case "rechte-befehl": return .command
        default: return .option
        }
    }

    func einrichten() {
        for m in monitore { NSEvent.removeMonitor(m) }
        monitore = []
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in self?.modifier(e) }) { monitore.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in self?.modifier(e); return e }) { monitore.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in self?.taste(e) }) { monitore.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in self?.taste(e); return e }) { monitore.append(m) }
    }

    /// Von außen beendet (z. B. Meeting startet oder Fehler): Zustand zurücksetzen.
    func zuruecksetzen() {
        aktiv = false
        freihaendig = false
        tippWarten?.cancel()
    }

    private func modifier(_ e: NSEvent) {
        guard e.keyCode == tastenCode else { return }
        let unten = e.modifierFlags.contains(flagge)
        if unten && !gedrueckt {
            gedrueckt = true
            druckZeit = Date()
            kombiniert = false
            if freihaendig {
                // Tippen im freihändigen Modus beendet die Aufnahme.
                freihaendig = false
                aktiv = false
                melden(.stopp)
                return
            }
            if aktiv, Date().timeIntervalSince(letzterTipp) < doppelFenster {
                // Zweiter Tipp: Aufnahme läuft schon seit dem ersten Tipp weiter.
                tippWarten?.cancel()
                freihaendig = true
                melden(.freihaendig)
                return
            }
            if !aktiv {
                aktiv = true
                melden(.start)
            }
        } else if !unten && gedrueckt {
            gedrueckt = false
            guard aktiv, !freihaendig else { return }
            if kombiniert {
                aktiv = false
                melden(.verwerfen)
                return
            }
            let dauer = Date().timeIntervalSince(druckZeit)
            if dauer >= haltenAb {
                aktiv = false
                melden(.stopp)
            } else {
                // Kurzer Tipp: kurz warten, ob ein zweiter kommt. Sonst war es nichts.
                letzterTipp = Date()
                let arbeit = DispatchWorkItem { [weak self] in
                    guard let self, self.aktiv, !self.freihaendig, !self.gedrueckt else { return }
                    self.aktiv = false
                    self.melden(.verwerfen)
                }
                tippWarten = arbeit
                DispatchQueue.main.asyncAfter(deadline: .now() + doppelFenster, execute: arbeit)
            }
        }
    }

    private func taste(_ e: NSEvent) {
        guard aktiv else { return }
        if e.keyCode == 53 {  // Esc
            zuruecksetzen()
            melden(.verwerfen)
            return
        }
        if gedrueckt && !freihaendig { kombiniert = true }
    }
}

// MARK: Einfügen in die App, die gerade vorne ist

enum Einfuegen {
    static func text(_ text: String, zuruecklegen: Bool = true) -> Bool {
        let tafel = NSPasteboard.general
        let vorher = tafel.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var kopie: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let d = item.data(forType: t) { kopie[t] = d } }
            return kopie
        } ?? []
        tafel.clearContents()
        tafel.setString(text, forType: .string)
        guard AXIsProcessTrusted() else { return false }
        let quelle = CGEventSource(stateID: .combinedSessionState)
        let runter = CGEvent(keyboardEventSource: quelle, virtualKey: 9, keyDown: true)
        let hoch = CGEvent(keyboardEventSource: quelle, virtualKey: 9, keyDown: false)
        runter?.flags = .maskCommand
        hoch?.flags = .maskCommand
        runter?.post(tap: .cghidEventTap)
        hoch?.post(tap: .cghidEventTap)
        if zuruecklegen {
            // Die alte Zwischenablage zurücklegen, nachdem die App eingefügt hat.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard tafel.string(forType: .string) == text else { return }
                tafel.clearContents()
                let items = vorher.map { kopie -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (t, d) in kopie { item.setData(d, forType: t) }
                    return item
                }
                if !items.isEmpty { tafel.writeObjects(items) }
            }
        }
        return true
    }

    static func kopieren(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
