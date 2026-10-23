import AppKit
import AVFoundation
import ApplicationServices
import UniformTypeIdentifiers

// Koe (声, „Stimme“): lokales Diktat, Meetings und Dateien transkribieren. Nichts verlässt den Mac.

final class Koe: NSObject, NSApplicationDelegate {
    let speicher = Speicher()
    let dienste = Dienste()
    let taste = Taste()
    let mikrofon = Mikrofon()
    let systemton = Systemton()
    let pille = Pille()
    lazy var transkription = Transkription(speicher: speicher)
    lazy var fenster = Fenster()

    private var statusItem: NSStatusItem!
    private var aufnahmeArt: String?          // nil | "diktat" | "meeting"
    private var aufnahmeSeit: Double = 0
    private var meetingId: String?
    private var diktatApp = ""
    private var feedbackArbeit: DispatchWorkItem?
    private var pegelTimer: Timer?
    private var rechteTimer: Timer?
    private var bedienungshilfenVorher = false
    private var zustandGeplant = false
    private var gemmaWeckt = false
    private var gemmaTimer: Timer?
    private var whisperWeckt = false
    /// Wie lange das letzte Wecken der Spracherkennung gedauert hat (fürs Protokoll). Über 2 s heißt: sie war ausgelagert.
    private var whisperWeckDauer: TimeInterval?
    /// Bei „Automatisch“ probiert Koe zuerst die Sprache des letzten Diktats. Meist bleibt sie gleich, dann reicht ein Durchgang.
    private var letzteSprache = "de"

    func applicationDidFinishLaunching(_ n: Notification) {
        Ports.laden()
        // Koe erscheint im Dock mit Punkt, solange es läuft, und im App-Umschalter (⌘-Tab).
        NSApp.setActivationPolicy(.regular)
        hauptmenueEinrichten()
        menueEinrichten()

        dienste.geaendert = { [weak self] in self?.zustandSenden() }
        transkription.geaendert = { [weak self] in self?.zustandSenden() }
        transkription.fertig = { [weak self] id in
            guard let self, let m = self.speicher.meta(id) else { return }
            self.fenster.senden("meldung", ["text": "„\(m.titel)“ ist fertig transkribiert", "art": "info"])
        }
        fenster.befehl = { [weak self] cmd, d in self?.befehl(cmd, d) }
        fenster.web.dateienAbgelegt = { [weak self] urls in urls.forEach { self?.dateiAufnehmen($0) } }
        pille.pegelQuelle = { [weak self] in self?.mikrofon.aktuellerPegel ?? 0 }
        systemton.abgebrochen = { [weak self] text in
            self?.fenster.senden("meldung", ["text": "Mac-Ton wurde unterbrochen: \(text)", "art": "fehler"])
        }

        taste.art = speicher.einstellungen.taste
        taste.melden = { [weak self] e in self?.tastenEreignis(e) }
        bedienungshilfenVorher = AXIsProcessTrusted()
        taste.einrichten()

        dienste.starten(speicher.einstellungen)
        transkription.wiederaufnehmen()
        rechteAnfragen()

        // Rechte werden in den Systemeinstellungen erteilt; Koe merkt es von selbst.
        rechteTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let jetzt = AXIsProcessTrusted()
            if jetzt != self.bedienungshilfenVorher {
                self.bedienungshilfenVorher = jetzt
                self.taste.einrichten()
                self.zustandSenden()
            }
        }
        fenster.zeigen()
    }

    func applicationWillTerminate(_ n: Notification) {
        if aufnahmeArt == "meeting" { meetingStoppen(verwerfen: false) }
        dienste.stoppen()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        fenster.zeigen()
        return true
    }

    // MARK: Menüleiste

    private func menueEinrichten() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItemBild()
        let menue = NSMenu()
        menue.delegate = self
        statusItem.menu = menue
    }

    /// Die Menüzeile oben, wenn Koe vorne ist. Ohne sie gehen ⌘Q, ⌘W, ⌘C und ⌘V im Fenster nicht.
    private func hauptmenueEinrichten() {
        let haupt = NSMenu()
        func untermenue(_ titel: String, _ eintraege: [(String, Selector?, String)]) -> NSMenu {
            let m = NSMenu(title: titel)
            for (t, aktion, taste) in eintraege {
                if t == "-" { m.addItem(.separator()); continue }
                m.addItem(NSMenuItem(title: t, action: aktion, keyEquivalent: taste))
            }
            let kopf = NSMenuItem()
            kopf.submenu = m
            haupt.addItem(kopf)
            return m
        }
        let app = untermenue("Koe", [
            ("Über Koe", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""), ("-", nil, ""),
            ("Koe ausblenden", #selector(NSApplication.hide(_:)), "h"), ("-", nil, ""),
            ("Koe beenden", #selector(NSApplication.terminate(_:)), "q"),
        ])
        app.items.forEach { if $0.action != nil { $0.target = NSApp } }
        _ = untermenue("Bearbeiten", [
            ("Widerrufen", Selector(("undo:")), "z"), ("Wiederholen", Selector(("redo:")), "Z"), ("-", nil, ""),
            ("Ausschneiden", #selector(NSText.cut(_:)), "x"), ("Kopieren", #selector(NSText.copy(_:)), "c"),
            ("Einfügen", #selector(NSText.paste(_:)), "v"), ("Alles auswählen", #selector(NSText.selectAll(_:)), "a"),
        ])
        let fensterMenue = untermenue("Fenster", [
            ("Schließen", #selector(NSWindow.performClose(_:)), "w"),
            ("Im Dock ablegen", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        NSApp.mainMenu = haupt
        NSApp.windowsMenu = fensterMenue
    }

    private func statusItemBild() {
        let name = aufnahmeArt == nil ? "waveform" : "waveform.circle.fill"
        let bild = NSImage(systemSymbolName: name, accessibilityDescription: "Koe")
        bild?.isTemplate = true
        statusItem.button?.image = bild
    }

    @objc private func fensterZeigen() { fenster.zeigen() }
    @objc private func meetingUmschalten() {
        if aufnahmeArt == "meeting" { meetingStoppen(verwerfen: false) } else { meetingStarten(titel: "", systemton: speicher.einstellungen.systemton) }
    }
    @objc private func dateiWaehlen() { dateiDialog() }
    @objc private func beenden() { NSApp.terminate(nil) }

    // MARK: Zustand an die Oberfläche

    func zustandSenden() {
        guard !zustandGeplant else { return }
        zustandGeplant = true
        DispatchQueue.main.async {
            self.zustandGeplant = false
            self.fenster.senden("zustand", self.zustand())
            self.statusItemBild()
        }
    }

    private func zustand() -> [String: Any] {
        let e = speicher.einstellungen
        let mikro: String = {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return "ja"
            case .notDetermined: return "offen"
            default: return "nein"
            }
        }()
        return [
            "dienste": ["whisper": dienste.whisper.dict, "llm": dienste.llm.dict, "sprecher": dienste.sprecher.dict],
            "rechte": ["mikrofon": mikro, "bedienungshilfen": AXIsProcessTrusted() ? "ja" : "nein",
                       "bildschirm": CGPreflightScreenCaptureAccess() ? "ja" : "nein"],
            "einstellungen": [
                "taste": e.taste, "sprache": e.sprache, "aufraeumen": e.aufraeumen, "einfuegen": e.einfuegen,
                "toene": e.toene, "systemton": e.systemton, "woerter": e.woerter,
                "ersetzungen": e.ersetzungen.map { ["von": $0.von, "nach": $0.nach] },
            ],
            "aufnahme": ["art": aufnahmeArt.map { $0 as Any } ?? NSNull(), "seit": aufnahmeSeit,
                         "titel": meetingId.flatMap { speicher.meta($0)?.titel } ?? ""],
            "diktate": speicher.diktate.prefix(300).map {
                ["id": $0.id, "zeit": $0.zeit, "dauer": $0.dauer, "roh": $0.roh, "text": $0.text, "app": $0.app] as [String: Any]
            },
            "transkripte": speicher.transkripte.map {
                ["id": $0.id, "titel": $0.titel, "zeit": $0.zeit, "dauer": $0.dauer, "quelle": $0.quelle, "status": $0.status,
                 "schritt": $0.schritt, "fortschritt": $0.fortschritt, "fehler": $0.fehler, "woerter": $0.woerter,
                 "sprecher": $0.sprecher] as [String: Any]
            },
            "speicherort": Pfade.basis.path,
        ]
    }

    // MARK: Befehle aus der Oberfläche

    private func befehl(_ cmd: String, _ d: [String: Any]) {
        let id = d["id"] as? String ?? ""
        switch cmd {
        case "bereit":
            zustandSenden()
        case "einstellungen.speichern":
            if let roh = d["einstellungen"], let daten = try? JSONSerialization.data(withJSONObject: roh),
               let neu = try? JSONDecoder().decode(Einstellungen.self, from: daten) {
                speicher.einstellungen = neu
                speicher.einstellungenSichern()
                taste.art = neu.taste
                dienste.anpassen(neu)
            }
            zustandSenden()
        case "meeting.start":
            meetingStarten(titel: d["titel"] as? String ?? "", systemton: d["systemton"] as? Bool ?? true)
        case "meeting.stop":
            meetingStoppen(verwerfen: false)
        case "meeting.verwerfen":
            meetingStoppen(verwerfen: true)
        case "datei.waehlen":
            dateiDialog()
        case "transkript.laden":
            guard let m = speicher.meta(id) else { return }
            fenster.senden("transkript", ["id": id, "namen": m.namen,
                                          "segmente": speicher.segmente(id).map { ["start": $0.start, "ende": $0.ende, "sprecher": $0.sprecher, "text": $0.text] }])
        case "transkript.umbenennen":
            let titel = (d["titel"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !titel.isEmpty else { return }
            speicher.aendern(id) { $0.titel = titel }
            transkription.markdownSichern(id)
            zustandSenden()
        case "transkript.sprecher":
            let namen = d["namen"] as? [String: String] ?? [:]
            speicher.aendern(id) { m in for (k, v) in namen { m.namen[k] = v.trimmingCharacters(in: .whitespaces) } }
            transkription.markdownSichern(id)
            befehl("transkript.laden", ["id": id])
            zustandSenden()
        case "transkript.kopieren":
            Einfuegen.kopieren(transkription.klartext(id, markdown: false))
            fenster.senden("meldung", ["text": "Transkript kopiert", "art": "info"])
        case "transkript.exportieren":
            exportieren(id)
        case "transkript.finder":
            NSWorkspace.shared.activateFileViewerSelecting([speicher.ordner(id).appendingPathComponent("transkript.md")])
        case "transkript.loeschen":
            transkription.abbrechen(id)
            speicher.loeschen(id)
            zustandSenden()
        case "diktat.kopieren":
            if let t = speicher.diktate.first(where: { $0.id == id })?.text {
                Einfuegen.kopieren(t)
                fenster.senden("meldung", ["text": "Diktat kopiert", "art": "info"])
            }
        case "diktat.loeschen":
            speicher.diktate.removeAll { $0.id == id }
            speicher.diktateSichern()
            zustandSenden()
        case "recht.oeffnen":
            rechtOeffnen(d["recht"] as? String ?? "")
        case "dienste.neustart":
            dienste.neustart(speicher.einstellungen)
        case "ordner.oeffnen":
            NSWorkspace.shared.open(Pfade.basis)
        default:
            protokoll("Unbekannter Befehl: \(cmd)")
        }
    }

    // MARK: Rechte

    private func rechteAnfragen() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in self?.zustandSenden() }
        }
        if !AXIsProcessTrusted() {
            let option = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([option: true] as CFDictionary)
        }
    }

    private func rechtOeffnen(_ recht: String) {
        let anker: String
        switch recht {
        case "mikrofon":
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in self?.zustandSenden() }
                return
            }
            anker = "Privacy_Microphone"
        case "bedienungshilfen": anker = "Privacy_Accessibility"
        case "bildschirm":
            if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
            anker = "Privacy_ScreenCapture"
        default: return
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anker)")!)
    }

    // MARK: Diktat

    private func tastenEreignis(_ e: Taste.Ereignis) {
        switch e {
        case .start:
            guard aufnahmeArt == nil else { taste.zuruecksetzen(); return }
            guard dienste.whisper.status == "bereit" else {
                taste.zuruecksetzen()
                pille.zeigen(.hinweis(dienste.whisper.status == "startet" ? "Spracherkennung lädt noch" : "Spracherkennung nicht bereit"))
                return
            }
            do {
                try mikrofon.starten()
            } catch {
                taste.zuruecksetzen()
                pille.zeigen(.hinweis("Mikrofon nicht verfügbar"))
                return
            }
            aufnahmeArt = "diktat"
            aufnahmeSeit = jetztMs()
            whisperWecken()
            gemmaWecken()
            gemmaTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.gemmaWecken() }
            diktatApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            // Rückmeldung erst, wenn klar ist, dass es kein kurzer Tipper oder eine Tastenkombination war.
            let arbeit = DispatchWorkItem { [weak self] in
                guard let self, self.aufnahmeArt == "diktat" else { return }
                self.ton("Tink")
                self.pille.zeigen(.aufnahme)
            }
            feedbackArbeit = arbeit
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: arbeit)
        case .freihaendig:
            feedbackArbeit?.cancel()
            pille.zeigen(.freihaendig)
            ton("Tink")
        case .verwerfen:
            feedbackArbeit?.cancel()
            gemmaTimer?.invalidate()
            gemmaTimer = nil
            guard aufnahmeArt == "diktat" else { return }
            mikrofon.stoppen()
            aufnahmeArt = nil
            pille.zeigen(.aus)
        case .stopp:
            feedbackArbeit?.cancel()
            gemmaTimer?.invalidate()
            gemmaTimer = nil
            guard aufnahmeArt == "diktat" else { return }
            let hoechster = mikrofon.hoechsterPegel
            let samples = mikrofon.stoppen()
            aufnahmeArt = nil
            ton("Pop")
            let dauer = Double(samples.count) / 16000
            if dauer < 0.4 || hoechster < 0.12 {
                pille.zeigen(.hinweis("Nichts gehört"))
                return
            }
            pille.zeigen(.verarbeite)
            gemmaWecken()   // läuft parallel zur Spracherkennung und bremst sie nicht
            let app = diktatApp
            Task { await self.diktatVerarbeiten(samples, dauer: dauer, app: app) }
        }
    }

    /// Hält Gemma wach, solange gesprochen wird: beim Drücken der Taste, alle 1,5 s während der Aufnahme und
    /// beim Loslassen. Schon nach rund 10 s Pause fährt der Mac die Grafikeinheit herunter, dann braucht das
    /// Aufräumen 2,5 s statt 0,5 s. Ein Stupser ist ein Token Antwort und kostet wach rund 0,1 s.
    private func gemmaWecken() {
        let e = speicher.einstellungen
        guard e.aufraeumen, dienste.llm.status == "bereit", !gemmaWeckt else { return }
        gemmaWeckt = true
        Task {
            await Textarbeit.aufwecken(woerter: e.woerter, sprache: ["ja", "zh"].contains(e.sprache) ? e.sprache : "de")
            await MainActor.run { self.gemmaWeckt = false }
        }
    }

    /// Weckt die Spracherkennung beim Drücken der Taste. Das Nachladen nach einer Pause läuft dann, während
    /// gesprochen wird, und nicht erst nach dem Loslassen. Wach kostet das rund 0,8 s, die man nicht merkt.
    private func whisperWecken() {
        guard dienste.whisper.status == "bereit", !whisperWeckt else { return }
        whisperWeckt = true
        whisperWeckDauer = nil
        Task {
            let dauer = await Textarbeit.whisperAufwecken()
            await MainActor.run {
                self.whisperWeckt = false
                self.whisperWeckDauer = dauer
            }
        }
    }

    private func diktatVerarbeiten(_ samples: [Float], dauer: Double, app: String) async {
        let e = speicher.einstellungen
        let t0 = Date()
        let wav = wavDaten(samples)
        /// Eine Anfrage an whisper-server. Mit `sprache` ist die Sprache fest, sonst gilt die beim Start gewählte.
        /// `liste` holt zusätzlich die Wahrscheinlichkeit jeder Sprache (verbose_json).
        func anfrage(_ sprache: String?, liste: Bool) async throws -> [String: Any] {
            var felder = ["response_format": liste ? "verbose_json" : "json", "temperature": "0"]
            if let sprache { felder["language"] = sprache }
            if let prompt = Textarbeit.whisperPrompt(e.woerter, sprache: sprache ?? e.sprache) { felder["prompt"] = prompt }
            return try await HTTP.multipart("http://127.0.0.1:\(Ports.whisper)/inference", felder: felder,
                                            datei: wav, dateiname: "diktat.wav", timeout: 60)
        }
        let roh: String
        var sprachInfo = ""
        do {
            var antwort: [String: Any]
            if e.sprache == "auto" {
                // Erst in der Sprache des letzten Diktats transkribieren und dabei Whispers Einschätzung mitnehmen.
                // Ist eine andere der erlaubten Sprachen wahrscheinlicher, ein zweiter Durchgang fest in dieser Sprache.
                // Fest in der falschen Sprache übersetzt Whisper nämlich, statt mitzuschreiben.
                let versuch = await MainActor.run { letzteSprache }
                antwort = try await anfrage(versuch, liste: true)
                if let beste = Textarbeit.besteSprache(antwort) {
                    sprachInfo = "Sprache \(beste.sprache) \(String(format: "%.2f", beste.p))"
                    if beste.sprache != versuch {
                        antwort = try await anfrage(beste.sprache, liste: false)
                        sprachInfo += ", zweiter Durchgang statt \(versuch)"
                    }
                    await MainActor.run { letzteSprache = beste.sprache }
                } else {
                    sprachInfo = "Sprache \(versuch), keine Einschätzung"
                }
            } else {
                antwort = try await anfrage(nil, liste: false)
            }
            roh = Textarbeit.ersetzen(Textarbeit.glaetten(antwort["text"] as? String ?? ""), e.ersetzungen)
        } catch {
            protokoll("Diktat: Spracherkennung fehlgeschlagen: \(error.localizedDescription)")
            await MainActor.run { pille.zeigen(.hinweis("Spracherkennung fehlgeschlagen")) }
            return
        }
        let erkennung = Date().timeIntervalSince(t0)
        if Textarbeit.istHalluzination(roh) {
            await MainActor.run { pille.zeigen(.hinweis("Nichts verstanden")) }
            return
        }
        var text = roh
        // Für das Protokoll: wie lange das Aufräumen gedauert hat und wie es ausging. Diktattexte kommen nicht ins Log.
        var aufraeumInfo = "Aufräumen aus"
        if e.aufraeumen, dienste.llm.status == "bereit", Textarbeit.anzahlWoerter(roh) >= 3 {
            // Ist Gemma noch am Aufwachen, erst darauf warten (höchstens 20 s). Sonst stellt sich das Aufräumen
            // hinten an, und das Zeitlimit läuft ab, bevor Gemma überhaupt dran ist. Dann käme nur der Rohtext.
            let tWarten = Date()
            while await MainActor.run(body: { self.gemmaWeckt }), Date().timeIntervalSince(tWarten) < 20 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let gewartet = Date().timeIntervalSince(tWarten)
            let t1 = Date()
            let sauber = await Textarbeit.aufraeumen(roh, woerter: e.woerter)
            var hinweise: [String] = []
            if let sauber {
                text = Textarbeit.ersetzen(sauber, e.ersetzungen)
                if text == roh { hinweise.append("nichts geändert") }
            } else {
                hinweise.append("ohne Ergebnis, Rohtext eingefügt")
            }
            if gewartet >= 0.3 { hinweise.append("vorher \(String(format: "%.1f", gewartet)) s aufs Aufwachen gewartet") }
            aufraeumInfo = "Aufräumen \(String(format: "%.1f", Date().timeIntervalSince(t1))) s"
                + (hinweise.isEmpty ? "" : " (\(hinweise.joined(separator: ", ")))")
        } else if e.aufraeumen {
            aufraeumInfo = dienste.llm.status == "bereit" ? "zu kurz zum Aufräumen" : "Gemma nicht bereit"
        }
        let ergebnis = text
        let info = aufraeumInfo
        let spracheText = sprachInfo
        await MainActor.run {
            let weckInfo = whisperWeckDauer.map { "Wecken \(String(format: "%.1f", $0)) s · " } ?? ""
            let eingefuegt = e.einfuegen && Einfuegen.text(ergebnis)
            if !eingefuegt { Einfuegen.kopieren(ergebnis) }
            pille.zeigen(eingefuegt ? .fertig : .hinweis(AXIsProcessTrusted() ? "In der Zwischenablage" : "Bedienungshilfen fehlen, Text liegt in der Zwischenablage"))
            ton("Glass")
            speicher.diktatHinzufuegen(Diktat(id: UUID().uuidString, zeit: jetztMs(), dauer: dauer, roh: roh, text: ergebnis, app: app))
            protokoll("Diktat: \(String(format: "%.1f", dauer)) s, \(Textarbeit.anzahlWoerter(ergebnis)) Wörter, \(app) · "
                      + weckInfo + "Erkennung \(String(format: "%.1f", erkennung)) s" + (spracheText.isEmpty ? "" : " (\(spracheText))") + " · \(info) · "
                      + "Wartezeit \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
            zustandSenden()
        }
    }

    private func ton(_ name: String) {
        guard speicher.einstellungen.toene else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    // MARK: Meetings

    private func meetingStarten(titel: String, systemton mitSystem: Bool) {
        guard aufnahmeArt == nil else {
            fenster.senden("meldung", ["text": "Es läuft schon eine Aufnahme", "art": "fehler"])
            return
        }
        if mitSystem && !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            fenster.senden("meldung", ["text": "Für den Mac-Ton braucht Koe das Recht „Bildschirm- und Systemaudioaufnahme“. Danach Koe neu starten.", "art": "fehler"])
            return
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "d. MMM, HH:mm"
        let name = titel.trimmingCharacters(in: .whitespaces).isEmpty ? "Meeting \(f.string(from: Date()))" : titel
        var meta = TranskriptMeta(id: neueId(), titel: name, zeit: jetztMs(), quelle: "meeting", status: "aufnahme")
        meta.mitSystemton = mitSystem
        speicher.neu(meta)
        let neueId = meta.id
        let ordner = speicher.ordner(neueId)
        do {
            try mikrofon.starten(datei: ordner.appendingPathComponent("mikro.wav"))
        } catch {
            speicher.loeschen(meta.id)
            fenster.senden("meldung", ["text": "Mikrofon konnte nicht starten: \(error.localizedDescription)", "art": "fehler"])
            return
        }
        meetingId = meta.id
        aufnahmeArt = "meeting"
        aufnahmeSeit = jetztMs()
        taste.zuruecksetzen()
        if mitSystem {
            Task {
                do {
                    try await self.systemton.starten(datei: ordner.appendingPathComponent("system.wav"))
                } catch {
                    await MainActor.run {
                        self.speicher.aendern(neueId) { $0.mitSystemton = false }
                        self.fenster.senden("meldung", ["text": "Mac-Ton läuft nicht mit: \(error.localizedDescription)", "art": "fehler"])
                    }
                }
            }
        }
        pegelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.fenster.senden("pegel", ["mikro": self.mikrofon.aktuellerPegel, "system": self.systemton.aktuellerPegel])
        }
        ton("Tink")
        zustandSenden()
    }

    private func meetingStoppen(verwerfen: Bool) {
        guard aufnahmeArt == "meeting", let id = meetingId else { return }
        pegelTimer?.invalidate()
        pegelTimer = nil
        let mikroStart = mikrofon.ersterPuffer
        mikrofon.stoppen()
        aufnahmeArt = nil
        meetingId = nil
        let mitSystem = speicher.meta(id)?.mitSystemton ?? false
        let fertigMachen = { [weak self] in
            guard let self else { return }
            if verwerfen {
                self.speicher.loeschen(id)
            } else {
                let sysStart = self.systemton.ersterPuffer
                self.speicher.aendern(id) { m in
                    m.status = "wartet"
                    m.schritt = "Wartet"
                    m.dauer = wavDauer(self.speicher.ordner(id).appendingPathComponent("mikro.wav"))
                    m.systemPegel = Double(self.systemton.hoechsterPegel)
                    if let a = mikroStart, let b = sysStart { m.systemVersatz = b.timeIntervalSince(a) }
                }
                self.transkription.einreihen(id)
            }
            self.ton("Pop")
            self.zustandSenden()
        }
        if mitSystem {
            Task {
                await self.systemton.stoppen()
                await MainActor.run { fertigMachen() }
            }
        } else {
            fertigMachen()
        }
    }

    // MARK: Dateien

    private func dateiDialog() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .mpeg4Audio]
        panel.message = "Audio- oder Videodatei wählen. Sie wird nur auf diesem Mac verarbeitet."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { panel.urls.forEach { dateiAufnehmen($0) } }
    }

    private func dateiAufnehmen(_ url: URL) {
        var meta = TranskriptMeta(id: neueId(), titel: url.deletingPathExtension().lastPathComponent, zeit: jetztMs(),
                                  quelle: "datei", status: "wartet", schritt: "Wartet")
        meta.originalName = url.lastPathComponent
        speicher.neu(meta)
        let ziel = speicher.ordner(meta.id).appendingPathComponent("original." + (url.pathExtension.isEmpty ? "bin" : url.pathExtension.lowercased()))
        do {
            try FileManager.default.copyItem(at: url, to: ziel)
        } catch {
            speicher.aendern(meta.id) { $0.status = "fehler"; $0.fehler = "Datei konnte nicht gelesen werden" }
            zustandSenden()
            return
        }
        transkription.einreihen(meta.id)
        fenster.zeigen()
        zustandSenden()
    }

    private func exportieren(_ id: String) {
        guard let m = speicher.meta(id) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = m.titel.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? transkription.klartext(id, markdown: true).write(to: url, atomically: true, encoding: .utf8)
        fenster.senden("meldung", ["text": "Gespeichert: \(url.lastPathComponent)", "art": "info"])
    }
}

extension Koe: NSMenuDelegate {
    // Das Menü wird beim Öffnen neu gebaut, damit es den aktuellen Stand zeigt.
    func menuNeedsUpdate(_ menue: NSMenu) {
        menue.removeAllItems()
        func eintrag(_ titel: String, _ aktion: Selector, _ taste: String = "") {
            let i = NSMenuItem(title: titel, action: aktion, keyEquivalent: taste)
            i.target = self
            menue.addItem(i)
        }
        let zustand = NSMenuItem(title: "Diktat: \(tastenText()) · Whisper \(dienste.whisper.status)", action: nil, keyEquivalent: "")
        zustand.isEnabled = false
        menue.addItem(zustand)
        menue.addItem(.separator())
        eintrag("Koe öffnen", #selector(fensterZeigen), "o")
        eintrag(aufnahmeArt == "meeting" ? "Meeting beenden und transkribieren" : "Meeting aufnehmen", #selector(meetingUmschalten), "m")
        eintrag("Datei transkribieren …", #selector(dateiWaehlen), "d")
        menue.addItem(.separator())
        eintrag("Koe beenden", #selector(beenden), "q")
    }

    private func tastenText() -> String {
        switch speicher.einstellungen.taste {
        case "fn": return "fn halten"
        case "rechte-befehl": return "rechte ⌘ halten"
        default: return "rechte ⌥ halten"
        }
    }
}

// MARK: Kommandozeile
// Koe.app/Contents/MacOS/Koe --cli datei <pfad> [--titel "…"]
//   transkribiert eine Datei lokal (large-v3 + Sprechertrennung) und gibt das Markdown aus.
//   Das Ergebnis erscheint auch in der App unter Meetings.

enum Kommandozeile {
    static func ausfuehren(_ args: [String]) -> Never {
        guard args.count >= 2, args[0] == "datei" else {
            FileHandle.standardError.write("Aufruf: Koe --cli datei <pfad> [--titel \"…\"]\n".data(using: .utf8)!)
            exit(2)
        }
        let quelle = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: quelle.path) else {
            FileHandle.standardError.write("Datei nicht gefunden: \(quelle.path)\n".data(using: .utf8)!)
            exit(1)
        }
        var titel = quelle.deletingPathExtension().lastPathComponent
        if let i = args.firstIndex(of: "--titel"), i + 1 < args.count { titel = args[i + 1] }

        Ports.laden()
        let speicher = Speicher()
        let transkription = Transkription(speicher: speicher)
        var meta = TranskriptMeta(id: neueId(), titel: titel, zeit: jetztMs(), quelle: "datei", status: "wartet", schritt: "Wartet")
        meta.originalName = quelle.lastPathComponent
        speicher.neu(meta)
        let ziel = speicher.ordner(meta.id).appendingPathComponent("original." + (quelle.pathExtension.isEmpty ? "bin" : quelle.pathExtension.lowercased()))
        do { try FileManager.default.copyItem(at: quelle, to: ziel) } catch {
            FileHandle.standardError.write("Kopieren fehlgeschlagen: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
        var letzterSchritt = ""
        transkription.geaendert = {
            guard let m = speicher.meta(meta.id) else { return }
            let zeile = "\(m.schritt) \(Int(m.fortschritt * 10) * 10) %"
            if zeile != letzterSchritt, !m.schritt.isEmpty {
                letzterSchritt = zeile
                FileHandle.standardError.write("\(zeile)\n".data(using: .utf8)!)
            }
            if m.status == "fehler" {
                FileHandle.standardError.write("Fehler: \(m.fehler)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        transkription.fertig = { id in
            let md = speicher.ordner(id).appendingPathComponent("transkript.md")
            FileHandle.standardError.write("Fertig: \(md.path)\n".data(using: .utf8)!)
            print(transkription.klartext(id, markdown: true))
            exit(0)
        }
        transkription.einreihen(meta.id)
        RunLoop.main.run()
        exit(0)
    }
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--cli" {
    Kommandozeile.ausfuehren(Array(CommandLine.arguments.dropFirst(2)))
}

let app = NSApplication.shared
let koe = Koe()
app.delegate = koe
app.run()
